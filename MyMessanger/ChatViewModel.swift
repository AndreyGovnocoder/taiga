//
//  ChatViewModel.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 14.03.2026.
//

import Foundation
import SwiftUI
import SwiftData
import UserNotifications
import Combine
import MessagingUI

// MARK: - ChatViewModel

/// ViewModel экрана чата — аналог ChatStore из MessengerSwiftDataDemo.
/// Window-based пагинация по SwiftData + подгрузка из Supabase.
@MainActor
@Observable
final class ChatViewModel {
    
    private(set) var chat: Chat
    
    // MARK: - Data Source для TiledView
    
    private(set) var dataSource = ListDataSource<ChatItem>()
    
    // MARK: - State
    
    var inputText: String = ""
    var isTyping: Bool = false
    private(set) var isInitialLoading: Bool = true
    private(set) var newMessagesWhileScrolledUp: Int = 0
    
    /// Сообщение, на которое отвечаем (reply-to)
    var replyToMessage: Message? = nil
    
    /// Устанавливается из ChatDetailView через onTiledScrollGeometryChange
    var isNearBottom: Bool = true
    
    // MARK: - Window-based Pagination
    
    private(set) var totalCount: Int = 0
    private var windowStart: Int = 0
    private var windowSize: Int = 0
    private let pageSize: Int = 50
    private var hasMoreOnServer: Bool = true
    
    /// Есть ещё сообщения: либо в локальном кэше, либо на сервере
    var hasMore: Bool { windowStart > 0 || hasMoreOnServer }
    
    // MARK: - Dependencies
    
    private var modelContext: ModelContext?
    let chatService: ChatServiceProtocol
    private var newMessageObserver: AnyCancellable?
    private var dbSaveObserver: AnyCancellable?
    private var networkRetryObserver: AnyCancellable?
    private var statusChangeObserver: AnyCancellable?
    private var realtimeDebounceTask: Task<Void, Never>?
    private var pendingEvents: Set<String> = []
    private var materializeTask: Task<String, Error>?
    
    // MARK: - Init
    
    init(chat: Chat, chatService: ChatServiceProtocol? = nil) {
        self.chat = chat
        self.chatService = chatService ?? SupabaseChatService()
    }
    
    // MARK: - Lifecycle
    
    /// Вызывается из ChatDetailView.onAppear
    func setup(context: ModelContext) {
        guard self.modelContext == nil else { return }
        self.modelContext = context
        observeNewMessages()
        observeNetworkRestored()
        observeMessageStatusChanged()
    }
    
    /// Начальная загрузка: сначала из SwiftData, потом фоном из Supabase
    func loadInitial() async {
        guard let context = modelContext else { return }
        isInitialLoading = true
        
        // Draft-чат — нечего загружать, чат ещё не создан
        if chat.isDraft {
            isInitialLoading = false
            return
        }
        
        // 1. МГНОВЕННО отображаем локальные сообщения
        totalCount = countLocalMessages()
        windowStart = max(0, totalCount - pageSize)
        windowSize = min(pageSize, totalCount)
        refreshWindow()
        
        // 2. Фоновый retry недоставленных
        await chatService.retryPendingMessages(context: context)
        
        // 3. Фоновая подгрузка свежих данных с сервера — с авто-retry на ТРАНЗИЕНТНЫХ
        //    сетевых сбоях (флапающая/throttled сеть, таймаут по полузависшему сокету).
        //    fetchMessages идемпотентен (dedup по id) → повтор безопасен. Best-effort:
        //    после исчерпания попыток показываем локальные сообщения (isInitialLoading снимется ниже).
        var fetchedCount = 0
        var attempt = 1
        while true {
            do {
                fetchedCount = try await chatService.fetchMessages(
                    for: chat.id,
                    limit: pageSize,
                    before: nil,
                    context: context
                )
                break
            } catch {
                if error.isTransientNetwork && attempt < 3 && !Task.isCancelled {
                    print("CHAT: Повтор загрузки сообщений после сетевого сбоя (попытка \(attempt))")
                    attempt += 1
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                print("CHAT: Не удалось загрузить сообщения: \(error.localizedDescription)")
                break
            }
        }

        hasMoreOnServer = fetchedCount >= pageSize
        
        // 4. Добавляем новые, если пришли
        let newTotal = countLocalMessages()
        let inserted = newTotal - totalCount
        if inserted > 0 {
            totalCount = newTotal
            windowSize += inserted
            refreshWindow()
        }
        
        isInitialLoading = false
    }
    
    /// Дозагрузка сообщений, пропущенных пока приложение было в фоне.
    /// iOS убивает WebSocket → realtime-события теряются.
    /// При пробуждении fetch покрывает gap, dedup не создаёт дубликатов.
    func refreshAfterWakeUp() async {
        guard let context = modelContext else { return }
        
        // Retry недоставленных при пробуждении
        await chatService.retryPendingMessages(context: context)
        
        // Загружаем увеличенную порцию (4x pageSize) чтобы не пропустить сообщения за время сна
        let catchUpLimit = pageSize * 4
        let fetched = try? await chatService.fetchMessages(
            for: chat.id,
            limit: catchUpLimit,
            before: nil,
            context: context
        )
        
        let newTotal = countLocalMessages()
        let inserted = newTotal - totalCount
        if inserted > 0 {
            totalCount = newTotal
            windowSize += inserted
        }
        refreshWindow()
        await markAsRead()
        
        print("CHAT: refreshAfterWakeUp — fetched \(fetched ?? 0), inserted \(inserted), total \(newTotal)")
    }
    
    // MARK: - Pagination
    
    /// Загрузка старых сообщений (вызывается из prependLoader)
    /// Cache-first: расширяем окно из SwiftData, дозагружаем с сервера если нужно.
    /// Один refreshWindow() в конце — чтобы не ломать цикл prependLoader.
    func loadOlder() async {
        guard let context = modelContext, hasMore else { return }
        
        // 1. Расширяем окно из локального SwiftData (без сети)
        if windowStart > 0 {
            let prepend = min(pageSize, windowStart)
            windowStart -= prepend
            windowSize += prepend
        }
        
        // 2. Если кэш исчерпан — дозагружаем с Supabase
        if windowStart == 0 && hasMoreOnServer {
            let oldestDate = dataSource.items.first?.message.createdAt
            
            let serverCount = (try? await chatService.fetchMessages(
                for: chat.id,
                limit: pageSize,
                before: oldestDate,
                context: context
            )) ?? 0
            
            if serverCount < pageSize {
                hasMoreOnServer = false
            }
            
            // Пересчитываем после вставки
            let newTotal = countLocalMessages()
            let inserted = newTotal - totalCount
            totalCount = newTotal
            
            // Сдвигаем окно на вставленные
            windowStart += inserted
            
            // Расширяем окно
            let prependAfterFetch = min(pageSize, windowStart)
            windowStart -= prependAfterFetch
            windowSize += prependAfterFetch
        }
        
        // 3. Один рефреш в конце — не ломаем цикл prependLoader
        refreshWindow()
    }
    
    // MARK: - Send Message
    
    func sendMessage() async {
        guard let context = modelContext else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        let replyId = replyToMessage?.id
        inputText = ""
        replyToMessage = nil
        
        // Фаза 1: мгновенная вставка (даже для draft — отобразится со статусом 🕐)
        let localChatId = chat.id
        guard let messageId = try? chatService.insertLocalMessage(
            chatId: localChatId,
            content: .text(text),
            replyToMessageId: replyId,
            threadRootId: nil,
            context: context
        ) else { return }
        
        // Обновляем окно — сообщение видно мгновенно
        let newTotal = countLocalMessages()
        let inserted = newTotal - totalCount
        windowSize += inserted
        totalCount = newTotal
        refreshWindow()
        
        // Фаза 2: фоновая доставка на сервер
        Task {
            do {
                if chat.isDraft {
                    _ = try await waitOrStartMaterialization(context: context)
                }
                
                try await chatService.deliverMessage(messageId: messageId, context: context)
            } catch {
                print("SEND: Ошибка доставки: \(error.localizedDescription)")
            }
            // Обновляем иконку статуса (.sending → .sent/.failed)
            refreshWindow()
        }
    }
    
    // MARK: - Send Media Messages
    
    func sendMediaMessages(datas: [Data], caption: String?) async {
        guard let context = modelContext else { return }
        let replyId = replyToMessage?.id
        replyToMessage = nil
        
        // Материализация draft-чата (если нужна)
        if chat.isDraft {
            do {
                _ = try await waitOrStartMaterialization(context: context)
            } catch {
                print("SEND MEDIA: Ошибка создания чата: \(error.localizedDescription)")
                return
            }
        }
        
        // Единый поток: локальная вставка + загрузка + доставка (один UUID на весь путь)
        // SupabaseChatService сама создаёт MessageDB с правильным содержимым
        await chatService.sendMediaMessages(
            chatId: chat.id,
            datas: datas,
            text: caption,
            replyToMessageId: replyId,
            threadRootId: nil,
            context: context
        )
        
        // Обновляем окно — сообщения уже вставлены SupabaseChatService
        let newTotal = countLocalMessages()
        let inserted = newTotal - totalCount
        if inserted > 0 {
            windowSize += inserted
            totalCount = newTotal
        }
        refreshWindow()
    }
    
    // MARK: - Draft Materialization
    
    /// Ожидает завершения текущей материализации или запускает новую
    @discardableResult
    func waitOrStartMaterialization(context: ModelContext) async throws -> String {
        if !chat.isDraft { return chat.id }
        
        if let task = materializeTask {
            print("ChatVM: Ожидание текущей материализации...")
            return try await task.value
        } else {
            print("ChatVM: Запуск материализации draft-чата...")
            let task = Task<String, Error> {
                try await materializeDraft(context: context)
            }
            materializeTask = task
            let realChatId = try await task.value
            materializeTask = nil
            print("ChatVM: Draft материализован → chatId: \(realChatId)")
            return realChatId
        }
    }
    
    /// Создаём реальный чат на сервере из draft. Возвращает реальный chatId.
    @discardableResult
    private func materializeDraft(context: ModelContext) async throws -> String {
        guard let targetUserId = chat.draftTargetUserId else {
            throw NSError(domain: "ChatViewModel", code: 400, userInfo: [NSLocalizedDescriptionKey: "Некорректный draft-чат"])
        }
        
        let draftId = chat.id
        let realChat = try await chatService.createOrGetPersonalChat(with: targetUserId, context: context)
        
        // Обновляем chat с реальным id
        self.chat = realChat
        
        // Обновляем chatId у зависших MessageDB с draft_id
        let draftPredicate = #Predicate<MessageDB> { $0.chatId == draftId }
        if let draftMessages = try? context.fetch(FetchDescriptor<MessageDB>(predicate: draftPredicate)) {
            for msg in draftMessages {
                msg.chatId = realChat.id
            }
            try? context.save()
        }
        
        print("DRAFT: Чат материализован: \(draftId) → \(realChat.id)")
        return realChat.id
    }
    
    // MARK: - Reply
    
    func setReply(_ message: Message) {
        replyToMessage = message
    }
    
    func cancelReply() {
        replyToMessage = nil
    }
    
    // MARK: - Retry Image Message
    
    /// Повторная отправка изображения по тапу (tap-to-retry).
    /// Текстовые сообщения ретраятся автоматически, изображения — только вручную.
    func retryImageMessage(_ message: Message) async {
        guard let context = modelContext else { return }
        
        // Мгновенно убрать retry overlay: ставим .sending и обновляем UI
        let msgId = message.id
        var desc = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == msgId })
        desc.fetchLimit = 1
        if let dbMsg = try? context.fetch(desc).first {
            dbMsg.status = .sending
            try? context.save()
        }
        refreshWindow()
        
        // Фоновая повторная отправка
        do {
            try await chatService.retryMessage(message, context: context)
        } catch {
            print("RETRY IMAGE: Ошибка повторной отправки: \(error.localizedDescription)")
        }
        refreshWindow()
    }
    
    // MARK: - Delete Message
    
    func deleteMessage(_ message: Message, state: SharedSelectionState? = nil) async {
        guard let context = modelContext else { return }
        
        if let state {
            await MainActor.run {
                _ = state.deletingIds.insert(message.id)
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
        
        do {
            try await chatService.deleteMessageEphemeral(message, context: context)
            await MainActor.run {
                if let state {
                    _ = state.deletingIds.remove(message.id)
                }
                totalCount = max(0, totalCount - 1)
                windowSize = max(0, windowSize - 1)
                refreshWindow()
            }
        } catch {
            print("ОШИБКА: Не удалось удалить сообщение: \(error.localizedDescription)")
            if let state {
                await MainActor.run {
                    _ = state.deletingIds.remove(message.id)
                }
            }
        }
    }
    
    // MARK: - Batch Operations (Selection Mode)
    
    /// Копирование текста одного сообщения в буфер обмена
    func copyMessageText(_ message: Message) {
        let text: String
        switch message.content {
        case .text(let t): text = t
        case .image(_, _, let caption, _, _, _): text = caption ?? "📷 Фото"
        }
        UIPasteboard.general.string = text
    }
    
    /// Копирование текстов выбранных сообщений
    func copyMessagesText(ids: Set<String>) {
        let messages = resolveMessages(ids: ids)
        let texts = messages.map { msg -> String in
            switch msg.content {
            case .text(let t): return t
            case .image(_, _, let caption, _, _, _): return caption ?? "📷 Фото"
            }
        }
        UIPasteboard.general.string = texts.joined(separator: "\n")
    }
    
    /// Подготовка текста для ShareLink
    func shareMessagesText(ids: Set<String>) -> String {
        let messages = resolveMessages(ids: ids)
        return messages.map { msg -> String in
            switch msg.content {
            case .text(let t): return t
            case .image(_, _, let caption, _, _, _): return caption ?? "📷 Фото"
            }
        }.joined(separator: "\n")
    }
    
    /// Удаление выбранных сообщений (ephemeral: свои ≤TTL у всех, остальные локально)
    func deleteSelectedMessages(ids: Set<String>, state: SharedSelectionState? = nil) async -> Bool {
        guard let context = modelContext else { return false }
        
        let messages = resolveMessages(ids: ids)
        guard !messages.isEmpty else { return false }
        
        if let state {
            await MainActor.run {
                state.deletingIds.formUnion(messages.map(\.id))
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
        
        do {
            try await chatService.deleteMessagesEphemeral(messages, context: context)
            await MainActor.run {
                if let state {
                    state.deletingIds.subtract(messages.map(\.id))
                }
                totalCount = max(0, totalCount - messages.count)
                windowSize = max(0, windowSize - messages.count)
                refreshWindow()
            }
            return true
        } catch {
            print("ОШИБКА: Не удалось удалить сообщения: \(error.localizedDescription)")
            if let state {
                await MainActor.run {
                    state.deletingIds.subtract(messages.map(\.id))
                }
            }
            return false
        }
    }
    
    /// Проверяет, есть ли среди выбранных свои сообщения
    func hasOwnMessages(ids: Set<String>) -> Bool {
        resolveMessages(ids: ids).contains { $0.isCurrentUser }
    }
    
    /// Резолвит Message объекты из dataSource по id
    private func resolveMessages(ids: Set<String>) -> [Message] {
        dataSource.items
            .map(\.message)
            .filter { ids.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
    }
    
    // MARK: - Edit Message
    
    func editMessage(_ message: Message, newText: String) async {
        guard let context = modelContext else { return }
        do {
            try await chatService.editMessage(message, newText: newText, context: context)
            refreshWindow()
        } catch {
            print("ОШИБКА: Не удалось отредактировать сообщение: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Mark as Read
    
    func markAsRead() async {
        guard let context = modelContext else { return }
        try? await chatService.markChatAsRead(chatId: chat.id, context: context)
        
        // Пересчитываем общий бейдж по всем чатам
        let allChatsDesc = FetchDescriptor<ChatDB>()
        let allChats = (try? context.fetch(allChatsDesc)) ?? []
        let totalUnread = allChats.reduce(0) { $0 + $1.unreadCount }
        
        try? await UNUserNotificationCenter.current().setBadgeCount(totalUnread)
    }
    
    // MARK: - Private: Window Refresh
    
    /// Вызывается после закрытия thread view.
    /// Пересчитывает windowSize чтобы включить сообщения, добавленные из ветки.
    func refreshAfterThreadDismiss() {
        let newTotal = countLocalMessages()
        let inserted = newTotal - totalCount
        if inserted > 0 {
            windowSize += inserted
            totalCount = newTotal
        }
        refreshWindow()
    }
    
    private var isRefreshingWindow = false
    private var needsRefreshWindow = false
    
    func refreshWindow() {
        if isRefreshingWindow {
            needsRefreshWindow = true
            return
        }
        isRefreshingWindow = true
        
        Task { @MainActor [weak self] in
            guard let self else { return }
            self._executeRefreshWindow()
            
            // Защита MessagingUI от краша UICollectionView (Invalid Batch Updates).
            // Ожидаем завершения внутреннего diffing-а и анимаций.
            try? await Task.sleep(for: .milliseconds(300))
            
            self.isRefreshingWindow = false
            if self.needsRefreshWindow {
                self.needsRefreshWindow = false
                self.refreshWindow()
            }
        }
    }
    
    private func _executeRefreshWindow() {
        guard let context = modelContext else { return }
        
        let chatId = chat.id
        var descriptor = FetchDescriptor<MessageDB>(
            predicate: #Predicate<MessageDB> { msg in
                msg.chatId == chatId && msg.isHiddenLocally == false
            },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchOffset = windowStart
        descriptor.fetchLimit = windowSize
        
        let models = (try? context.fetch(descriptor)) ?? []
        // UGC-модерация: на display-слое прячем сообщения заблокированных отправителей
        // (надёжнее, чем полагаться на isHiddenLocally при ре-fetch; группировка ниже
        // считается уже по видимым сообщениям).
        let blocked = SupabaseManager.shared.blockedUserIds
        let messages = models.map { $0.toDomain() }
            .filter { !blocked.contains($0.senderId) }

        // Собираем все replyToMessageId для batch-resolve
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
        
        // Формируем ChatItem с флагами разделителей дней.
        // Флаг включён в Equatable — UICollectionView перерисует ячейку
        // при смене статуса разделителя (например, после удаления сообщения).
        let calendar = Calendar.current
        var lastDate: Date? = nil
        
        // Подсчитываем размер ветки для сообщений с threadRootId
        var threadCountCache: [String: Int] = [:]
        
        let items: [ChatItem] = messages.enumerated().map { index, message in
            let messageDay = calendar.startOfDay(for: message.createdAt)
            
            let isFirstInGroup: Bool
            if index > 0 {
                let prevMsg = messages[index - 1]
                let isSameSender = prevMsg.senderId == message.senderId
                let isPrevDay = !calendar.isDate(messageDay, inSameDayAs: calendar.startOfDay(for: prevMsg.createdAt))
                isFirstInGroup = !isSameSender || isPrevDay
            } else {
                isFirstInGroup = true
            }
            
            let isLastInGroup: Bool
            if index < messages.count - 1 {
                let nextMsg = messages[index + 1]
                let isSameSender = nextMsg.senderId == message.senderId
                let isNextDay = !calendar.isDate(messageDay, inSameDayAs: calendar.startOfDay(for: nextMsg.createdAt))
                isLastInGroup = !isSameSender || isNextDay
            } else {
                isLastInGroup = true
            }
            
            let needsSeparator = lastDate == nil || !calendar.isDate(messageDay, inSameDayAs: lastDate!)
            lastDate = messageDay
            let replied = message.replyToMessageId.flatMap { repliedMap[$0] }
            
            // Резолв имени отправителя цитируемого сообщения
            let repliedName: String? = replied.map { repliedMsg in
                if repliedMsg.isCurrentUser { return "Вы" }
                return chat.participants.first(where: { $0.id == repliedMsg.senderId })?.name ?? "Собеседник"
            }
            
            // Подсчёт сообщений в ветке (кэшируем по root id)
            var threadCount: Int? = nil
            if let context = modelContext {
                // Определяем rootId: если у сообщения есть threadRootId — это оно; иначе проверяем не является ли само сообщение корнем
                let rootId: String
                if let trid = message.threadRootId {
                    rootId = trid
                } else {
                    rootId = message.id
                }
                
                if let cached = threadCountCache[rootId] {
                    threadCount = cached
                } else {
                    let descriptor = FetchDescriptor<MessageDB>(
                        predicate: #Predicate<MessageDB> { msg in msg.threadRootId == rootId }
                    )
                    let childCount = (try? context.fetchCount(descriptor)) ?? 0
                    if childCount > 0 {
                        // +1 за само корневое сообщение
                        let total = childCount + 1
                        threadCountCache[rootId] = total
                        threadCount = total
                    } else if message.threadRootId != nil {
                        threadCountCache[rootId] = 1
                        threadCount = 1
                    }
                }
            }
            
            return ChatItem(
                message: message,
                showDateSeparator: needsSeparator,
                repliedMessage: replied,
                repliedSenderName: repliedName,
                threadCount: threadCount,
                senderName: resolveSenderName(for: message),
                senderAvatar: resolveSenderAvatar(for: message),
                isGroupChat: chat.isGroup,
                isFirstFromSender: isFirstInGroup,
                isLastFromSender: isLastInGroup
            )
        }
        // Не вызываем apply, если элементы идентичны. Это предотвращает баг
        // UICollectionView (Invalid Batch Updates) при спаме обновлений.
        if Array(dataSource.items) != items {
            print("UI DEBUG: 🔄 Обновляем TiledView (было \(dataSource.items.count), стало \(items.count))")
            dataSource.apply(items)
        } else {
            print("UI DEBUG: ⏭ Игнорируем apply(items), элементы идентичны")
        }
    }
    
    /// Возвращает имя отправителя для группового чата.
    /// Для личных чатов и своих сообщений → nil (не отображать).
    private func resolveSenderName(for message: Message) -> String? {
        guard chat.isGroup, !message.isCurrentUser else { return nil }
        return chat.participants.first(where: { $0.id == message.senderId })?.name ?? "Участник"
    }
    
    /// Возвращает URL аватара для группового чата.
    private func resolveSenderAvatar(for message: Message) -> URL? {
        guard chat.isGroup, !message.isCurrentUser else { return nil }
        return chat.participants.first(where: { $0.id == message.senderId })?.avatar
    }
    
    private func countLocalMessages() -> Int {
        guard let context = modelContext else { return 0 }
        let chatId = chat.id
        let descriptor = FetchDescriptor<MessageDB>(
            predicate: #Predicate<MessageDB> { msg in
                msg.chatId == chatId && msg.isHiddenLocally == false
            }
        )
        return (try? context.fetchCount(descriptor)) ?? 0
    }
    
    // MARK: - Realtime: Incoming Messages
    
    /// Двойной наблюдатель: `.newMessageSaved` говорит КАКОЙ чат обновился,
    /// `ModelContext.didSave` говорит КОГДА данные доступны в main context.
    /// Оба сигнала вызывают `tryIncomingRefresh()`, но рефреш даёт результат
    /// только когда и флаг установлен, и `countLocalMessages()` видит новые данные.
    private func observeNewMessages() {
        // 1. Наше сообщение для этого чата — ставим флаг
        newMessageObserver = NotificationCenter.default
            .publisher(for: .newMessageSaved)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let incomingChatId = notification.object as? String,
                      incomingChatId.lowercased() == self.chat.id.lowercased() else {
                    return
                }
                let eventType = notification.userInfo?["eventType"] as? String ?? "inserted"
                print("UI: Получено уведомление о сообщении \(incomingChatId) типа \(eventType)")
                self.pendingEvents.insert(eventType)
                self.tryIncomingRefresh()
            }
        
        // 2. SwiftData сохранила данные — main context может их видеть
        dbSaveObserver = NotificationCenter.default
            .publisher(for: ModelContext.didSave)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.tryIncomingRefresh()
            }
    }
    
    /// Дебаунс-рефреш входящих. Рефрешит окно только если:
    /// - есть флаг pendingIncoming (наш чат получил сообщение)
    /// - countLocalMessages() вернул больше, чем было (данные доступны)
    private func tryIncomingRefresh() {
        print("UI: 🔄 tryIncomingRefresh вызван. pending: \(pendingEvents)")
        guard !pendingEvents.isEmpty else { return }
        
        realtimeDebounceTask?.cancel()
        realtimeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            
            let newTotal = self.countLocalMessages()
            let difference = newTotal - self.totalCount
            print("UI: 📊 tryIncomingRefresh -> newTotal: \(newTotal) (было \(self.totalCount)), diff: \(difference)")
            var didHandle = false
            
            if difference > 0 {
                print("UI: ➕ Обрабатываем вставку (difference > 0)")
                // Новые сообщения вставлены
                self.windowSize += difference
                self.totalCount = newTotal
                self.pendingEvents.remove("inserted")
                
                if self.isNearBottom {
                    await self.markAsRead()
                } else {
                    self.newMessagesWhileScrolledUp += difference
                }
                didHandle = true
            }
            
            if self.pendingEvents.contains("edited") || self.pendingEvents.contains("deleted") || difference < 0 {
                print("UI: ✏️🗑 Обрабатываем изменение (edit/delete/diff < 0)")
                if difference < 0 {
                    self.windowSize += difference
                    if self.windowSize < self.pageSize { self.windowSize = self.pageSize }
                    self.totalCount = newTotal
                }
                self.pendingEvents.remove("edited")
                self.pendingEvents.remove("deleted")
                didHandle = true
            }
            
            if didHandle {
                print("UI: 🚀 Вызываем refreshWindow()")
                self.refreshWindow()
            }
        }
    }
    
    /// Сброс badge при скролле вниз или нажатии кнопки
    func resetNewMessagesBadge() {
        newMessagesWhileScrolledUp = 0
    }
    
    // MARK: - Network Retry
    
    /// Подписка на восстановление сети для авторетрая .sending сообщений
    private func observeNetworkRestored() {
        networkRetryObserver = NotificationCenter.default
            .publisher(for: .networkRestored)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let context = self.modelContext else { return }
                Task { @MainActor in
                    await self.chatService.retryPendingMessages(context: context)
                    self.refreshWindow()
                }
            }
    }
    
    // MARK: - Status Change Observer
    
    /// Обновление UI при изменении статуса сообщения (после фоновой отправки изображений)
    private func observeMessageStatusChanged() {
        statusChangeObserver = NotificationCenter.default
            .publisher(for: .messageStatusChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let msgChatId = notification.object as? String,
                      msgChatId.lowercased() == self.chat.id.lowercased() else {
                    return
                }
                self.refreshWindow()
            }
    }
}
