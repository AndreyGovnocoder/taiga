//
//  ThreadViewModel.swift
//  MyMessanger
//
//  Created by Antigravity AI on 22.03.2026.
//

import Foundation
import SwiftData
import Combine
import MessagingUI

@MainActor @Observable
final class ThreadViewModel {
    let rootMessageId: String
    private let parentViewModel: ChatViewModel
    
    var chatId: String { parentViewModel.chat.id }
    var participants: [User] { parentViewModel.chat.participants }
    var isGroup: Bool { parentViewModel.chat.isGroup }
    
    // MARK: - Data Source для TiledView
    
    private(set) var dataSource = ListDataSource<ThreadItem>()
    
    // MARK: - State
    
    var inputText: String = ""
    var replyToMessage: Message? = nil
    
    /// ID сообщения для reply_to (при свайпе). Используется только для первого отправленного сообщения.
    var initialReplyToId: String?
    
    /// Были ли отправлены сообщения в этой сессии ветки
    private(set) var didSendMessages: Bool = false
    
    /// Есть ли ещё сообщения для загрузки при скролле вверх
    var hasMore: Bool { windowStart > 0 }
    
    // MARK: - Window-based Pagination
    
    private var totalCount: Int = 0
    private var windowStart: Int = 0
    private var windowSize: Int = 0
    private let pageSize: Int = 50
    
    // MARK: - Dependencies
    
    private var modelContext: ModelContext?
    private var chatService: ChatServiceProtocol { parentViewModel.chatService }
    
    var threadCount: Int { totalCount }
    
    init(rootMessageId: String, parentViewModel: ChatViewModel, initialReplyToId: String? = nil) {
        self.rootMessageId = rootMessageId
        self.parentViewModel = parentViewModel
        self.initialReplyToId = initialReplyToId
    }
    
    // MARK: - Load
    
    func loadThread(context: ModelContext) {
        self.modelContext = context
        
        totalCount = countLocalMessages()
        windowStart = max(0, totalCount - pageSize)
        windowSize = min(pageSize, totalCount)
        
        refreshWindow()
        subscribeToUpdates()
    }
    
    /// Подгрузка старых сообщений при скролле вверх
    func loadOlder() {
        guard windowStart > 0 else { return }
        
        let additionalCount = min(pageSize, windowStart)
        windowStart -= additionalCount
        windowSize += additionalCount
        
        refreshWindow()
    }
    
    // MARK: - Refresh Window
    
    func refreshWindow() {
        guard let context = modelContext else { return }
        let rootId = rootMessageId
        
        var descriptor = FetchDescriptor<MessageDB>(
            predicate: #Predicate<MessageDB> { msg in
                msg.threadRootId == rootId || msg.id == rootId
            },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchOffset = windowStart
        descriptor.fetchLimit = windowSize
        
        let dbMessages = (try? context.fetch(descriptor)) ?? []
        let messages = dbMessages.map { $0.toDomain() }
        
        // Batch-resolve reply-to
        let replyIds = Set(messages.compactMap { $0.replyToMessageId })
        var repliedMap: [String: Message] = [:]
        
        if !replyIds.isEmpty {
            for replyId in replyIds {
                let rid = replyId
                var replyDescriptor = FetchDescriptor<MessageDB>(
                    predicate: #Predicate<MessageDB> { msg in msg.id == rid }
                )
                replyDescriptor.fetchLimit = 1
                if let replyDB = try? context.fetch(replyDescriptor).first {
                    repliedMap[replyId] = replyDB.toDomain()
                }
            }
        }
        
        // Формируем ThreadItem с date separators
        let calendar = Calendar.current
        var lastDate: Date? = nil
        
        let items: [ThreadItem] = messages.map { message in
            let messageDay = calendar.startOfDay(for: message.createdAt)
            let needsSeparator = lastDate == nil || !calendar.isDate(messageDay, inSameDayAs: lastDate!)
            lastDate = messageDay
            let replied = message.replyToMessageId.flatMap { repliedMap[$0] }
            
            // Резолв имени отправителя цитируемого сообщения
            let repliedName: String? = replied.map { repliedMsg in
                if repliedMsg.isCurrentUser { return "Вы" }
                return participants.first(where: { $0.id == repliedMsg.senderId })?.name ?? "Собеседник"
            }
            
            return ThreadItem(message: message, showDateSeparator: needsSeparator, repliedMessage: replied, repliedSenderName: repliedName, senderName: resolveSenderName(for: message), senderAvatar: resolveSenderAvatar(for: message))
        }
        
        dataSource.apply(items)
    }
    
    /// Пересчёт totalCount и расширение окна для новых сообщений
    func refreshAfterNewMessage() {
        let newTotal = countLocalMessages()
        let added = newTotal - totalCount
        if added > 0 {
            windowSize += added
            totalCount = newTotal
        }
        refreshWindow()
    }
    
    // MARK: - Send
    
    /// Отправка сообщения из thread view.
    /// Первое сообщение при свайпе → reply_to = initialReplyToId (ID того сообщения по которому свайпнули).
    /// Остальные сообщения → reply_to = nil (thread_root_id отправляется напрямую в InsertDTO).
    func sendMessage() async {
        guard let context = modelContext else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        // reply_to ТОЛЬКО для первого сообщения (свайп) или свайп внутри ветки
        let replyId: String?
        if let swipeReply = replyToMessage {
            replyId = swipeReply.id
        } else if let initial = initialReplyToId {
            replyId = initial
            initialReplyToId = nil
        } else {
            replyId = nil // Без reply_to — thread_root_id проставится через InsertDTO
        }
        
        let content = MessageContent.text(text)
        
        inputText = ""
        replyToMessage = nil
        
        let currentChatId = parentViewModel.chat.id
        
        // Фаза 1: мгновенная вставка
        guard let messageId = try? chatService.insertLocalMessage(
            chatId: currentChatId,
            content: content,
            replyToMessageId: replyId,
            threadRootId: rootMessageId,
            context: context
        ) else { return }
        
        refreshAfterNewMessage()
        didSendMessages = true
        
        // Фаза 2: фоновая доставка
        Task {
            do {
                if parentViewModel.chat.isDraft {
                    _ = try await parentViewModel.waitOrStartMaterialization(context: context)
                }
                
                try await chatService.deliverMessage(messageId: messageId, context: context)
            } catch {
                print("THREAD: Ошибка доставки: \(error.localizedDescription)")
            }
            refreshWindow()
        }
    }
    
    /// Отправка изображений из thread view.
    func sendMediaMessages(datas: [Data], caption: String?) async {
        guard let context = modelContext else { return }
        
        await chatService.sendMediaMessages(
            chatId: chatId,
            datas: datas,
            text: caption,
            replyToMessageId: replyToMessage?.id ?? initialReplyToId,
            threadRootId: rootMessageId,
            context: context
        )
        
        initialReplyToId = nil
        replyToMessage = nil
        refreshAfterNewMessage()
        didSendMessages = true
    }
    
    /// Повторная отправка сообщения (tap-to-retry для изображений)
    func retryImageMessage(_ message: Message) async {
        guard let context = modelContext else { return }
        
        // Мгновенно убрать retry overlay
        let msgId = message.id
        var desc = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == msgId })
        desc.fetchLimit = 1
        if let dbMsg = try? context.fetch(desc).first {
            dbMsg.status = .sending
            try? context.save()
        }
        refreshWindow()
        
        do {
            try await chatService.retryMessage(message, context: context)
        } catch {
            print("THREAD RETRY: Ошибка повторной отправки: \(error.localizedDescription)")
        }
        refreshWindow()
    }
    
    // MARK: - Sender Name (для групповых чатов)
    
    private func resolveSenderName(for message: Message) -> String? {
        guard isGroup, !message.isCurrentUser else { return nil }
        return participants.first(where: { $0.id == message.senderId })?.name ?? "Участник"
    }

    private func resolveSenderAvatar(for message: Message) -> URL? {
        guard isGroup, !message.isCurrentUser else { return nil }
        return participants.first(where: { $0.id == message.senderId })?.avatar
    }
    
    // MARK: - Private
    
    private func countLocalMessages() -> Int {
        guard let context = modelContext else { return 0 }
        let rootId = rootMessageId
        let descriptor = FetchDescriptor<MessageDB>(
            predicate: #Predicate<MessageDB> { msg in
                msg.threadRootId == rootId || msg.id == rootId
            }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }
    
    // MARK: - Realtime
    
    private var cancellables: Set<AnyCancellable> = []
    
    private func subscribeToUpdates() {
        NotificationCenter.default.publisher(for: .newMessageSaved)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                if let notifChatId = notification.object as? String,
                   notifChatId.lowercased() == self.chatId.lowercased() {
                    self.refreshAfterNewMessage()
                }
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: ModelContext.didSave)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshAfterNewMessage()
            }
            .store(in: &cancellables)
    }
}
