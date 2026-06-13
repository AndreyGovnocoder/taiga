//
//  SwiftDataModels.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 10.03.2026.
//


import Foundation
import SwiftData

@Model
class UserDB {
    #Unique<UserDB>([\.id])
    var id: String
    var phoneNumber: String
    var name: String
    var nickname: String
    var avatarURL: URL?
    /// Полноразмерная версия аватара (профиль/fullscreen); avatarURL — компактная тумба.
    var avatarURLFull: URL?
    var isOnline: Bool = false

    init(id: String, phoneNumber: String, name: String, nickname: String, avatarURL: URL? = nil, avatarURLFull: URL? = nil, isOnline: Bool) {
        self.id = id
        self.phoneNumber = phoneNumber
        self.name = name
        self.nickname = nickname
        self.avatarURL = avatarURL
        self.avatarURLFull = avatarURLFull
        self.isOnline = isOnline
    }
}

@Model
class MessageDB {
    #Unique<MessageDB>([\.id])
    #Index<MessageDB>([\.chatId, \.createdAt])
    var id: String
    @Attribute var imageWidth: Double?
    @Attribute var imageHeight: Double?
    
    var chatId: String
    var senderId: String
    var replyToMessageId: String?
    var threadRootId: String?
    var content: MessageContent
    var createdAt: Date
    
    /// Строковое представление статуса для использования в #Predicate
    var statusRaw: String
    
    /// Локальное скрытие (удаление только у себя, без затрагивания сервера)
    var isHiddenLocally: Bool = false
    
    /// Computed property для удобного доступа
    @Transient
    var status: MessageStatus {
        get { MessageStatus(rawValue: statusRaw) ?? .sending }
        set { statusRaw = newValue.rawValue }
    }
    
    /// Истекло ли сообщение на сервере (старше TTL)
    @Transient
    var isExpiredOnServer: Bool {
        createdAt.addingTimeInterval(3 * 24 * 3600) < Date()
    }
    
    init(id: String, chatId: String, senderId: String, replyToMessageId: String? = nil, threadRootId: String? = nil, content: MessageContent, createdAt: Date, status: MessageStatus) {
        self.id = id
        self.chatId = chatId
        self.senderId = senderId
        self.replyToMessageId = replyToMessageId
        self.threadRootId = threadRootId
        self.content = content
        self.createdAt = createdAt
        self.statusRaw = status.rawValue
    }
}

@Model
class ChatDB {
    #Unique<ChatDB>([\.id])
    var id: String
    var type: ChatType
    var unreadCount: Int
    
    var participantIds: [String] = []
    var lastMessageId: String?
    var myRole: String = "member"
    var isMuted: Bool = false

    // MARK: - Snapshot последнего сообщения (денормализация)
    var lastMessageText: String?
    var lastMessageAt: Date?
    var lastMessageSenderId: String?
    var lastMessageType: String?

    // MARK: - Метки очистки/удаления (зеркало серверных chat_participants.cleared_at/deleted_at)
    /// Сообщения с createdAt <= clearedAt скрыты («очистить чат»). nil — чат не очищался.
    var clearedAt: Date?
    /// Чат «удалён» для меня, пока lastMessageAt <= deletedAt; более новое сообщение оживляет.
    var deletedAt: Date?

    init(id: String, type: ChatType, unreadCount: Int, participantIds: [String], lastMessageId: String? = nil, myRole: String = "member", isMuted: Bool = false, lastMessageText: String? = nil, lastMessageAt: Date? = nil, lastMessageSenderId: String? = nil, lastMessageType: String? = nil, clearedAt: Date? = nil, deletedAt: Date? = nil) {
        self.id = id
        self.type = type
        self.unreadCount = unreadCount
        self.participantIds = participantIds
        self.lastMessageId = lastMessageId
        self.myRole = myRole
        self.isMuted = isMuted
        self.lastMessageText = lastMessageText
        self.lastMessageAt = lastMessageAt
        self.lastMessageSenderId = lastMessageSenderId
        self.lastMessageType = lastMessageType
        self.clearedAt = clearedAt
        self.deletedAt = deletedAt
    }
}

extension ChatDB {
    /// Пересчёт денормализованного snapshot последнего сообщения из локальных данных.
    ///
    /// - respectServerRecency: режим для fetchChats. Серверный snapshot (только что записанный)
    ///   обычно НОВЕЕ локального (новейшее сообщение могло ещё не подгрузиться пагинацией),
    ///   поэтому его НЕ перетираем более старым локальным — иначе список показывает устаревшее
    ///   превью, пока не зайдёшь в чат. Перетираем только если знаем, что серверное последнее
    ///   сообщение локально СКРЫТО (сервер показывает скрытое), либо локальное не старше серверного.
    ///   По умолчанию (delete/clear/hide) snapshot строго следует за локальным состоянием.
    func updateSnapshot(context: ModelContext, respectServerRecency: Bool = false) {
        let cId = self.id

        // Последнее ВИДИМОЕ локальное сообщение.
        var visibleDesc = FetchDescriptor<MessageDB>(
            predicate: #Predicate<MessageDB> { $0.chatId == cId && $0.isHiddenLocally == false },
            sortBy: Array(arrayLiteral: SortDescriptor(\.createdAt, order: .reverse))
        )
        visibleDesc.fetchLimit = 1
        let newestVisible = try? context.fetch(visibleDesc).first

        if respectServerRecency {
            // Скрыто ли локально серверное последнее сообщение?
            var serverLastHidden = false
            if let sid = self.lastMessageId {
                let sDesc = FetchDescriptor<MessageDB>(predicate: #Predicate<MessageDB> { $0.id == sid })
                if let serverMsg = try? context.fetch(sDesc).first {
                    serverLastHidden = serverMsg.isHiddenLocally
                }
            }
            if serverLastHidden {
                applySnapshot(from: newestVisible)              // сервер показывает скрытое — берём локальное
            } else if let nv = newestVisible,
                      (self.lastMessageAt == nil || nv.createdAt >= self.lastMessageAt!) {
                applySnapshot(from: nv)                          // локальное не старше — принимаем
            }
            // иначе: серверный snapshot актуален/новее — НЕ трогаем
            return
        }

        // Локально-авторитетный режим (delete/clear/hide): snapshot строго следует за локальным.
        let allMsgDesc = FetchDescriptor<MessageDB>(predicate: #Predicate<MessageDB> { $0.chatId == cId })
        let totalCount = (try? context.fetchCount(allMsgDesc)) ?? 0
        guard totalCount > 0 else { return } // нет локальных сообщений — не трогаем серверный snapshot
        applySnapshot(from: newestVisible)   // newestVisible == nil → очистка (все скрыты)
    }

    /// Применяет snapshot из сообщения (nil — очищает: чат пуст или все сообщения скрыты).
    private func applySnapshot(from msg: MessageDB?) {
        guard let msg else {
            self.lastMessageId = nil
            self.lastMessageText = nil
            self.lastMessageAt = nil
            self.lastMessageSenderId = nil
            self.lastMessageType = nil
            return
        }
        self.lastMessageId = msg.id
        self.lastMessageAt = msg.createdAt
        self.lastMessageSenderId = msg.senderId
        if case .text(let text) = msg.content {
            self.lastMessageText = text
            self.lastMessageType = "text"
        } else if case .image(_, _, let text, _, _, _) = msg.content {
            self.lastMessageText = text
            self.lastMessageType = "image"
        }
    }
}
