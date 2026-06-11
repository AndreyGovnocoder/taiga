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
    var isOnline: Bool = false
    
    init(id: String, phoneNumber: String, name: String, nickname: String, avatarURL: URL? = nil, isOnline: Bool) {
        self.id = id
        self.phoneNumber = phoneNumber
        self.name = name
        self.nickname = nickname
        self.avatarURL = avatarURL
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
    
    init(id: String, type: ChatType, unreadCount: Int, participantIds: [String], lastMessageId: String? = nil, myRole: String = "member", isMuted: Bool = false, lastMessageText: String? = nil, lastMessageAt: Date? = nil, lastMessageSenderId: String? = nil, lastMessageType: String? = nil) {
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
    }
}

extension ChatDB {
    func updateSnapshot(context: ModelContext) {
        let cId = self.id
        
        // Проверяем: есть ли ВООБЩЕ локальные сообщения для этого чата?
        // Если нет — значит сообщения ещё не загружались, оставляем серверный snapshot.
        let allMsgDesc = FetchDescriptor<MessageDB>(
            predicate: #Predicate<MessageDB> { $0.chatId == cId }
        )
        let totalCount = (try? context.fetchCount(allMsgDesc)) ?? 0
        guard totalCount > 0 else { return } // нет локальных сообщений — не трогаем snapshot
        
        // Ищем последнее видимое сообщение
        var visibleDesc = FetchDescriptor<MessageDB>(
            predicate: #Predicate<MessageDB> { $0.chatId == cId && $0.isHiddenLocally == false },
            sortBy: Array(arrayLiteral: SortDescriptor(\.createdAt, order: .reverse))
        )
        visibleDesc.fetchLimit = 1
        
        if let prevMsg = try? context.fetch(visibleDesc).first {
            self.lastMessageId = prevMsg.id
            self.lastMessageAt = prevMsg.createdAt
            self.lastMessageSenderId = prevMsg.senderId
            if case .text(let text) = prevMsg.content {
                self.lastMessageText = text
                self.lastMessageType = "text"
            } else if case .image(_, _, let text, _, _, _) = prevMsg.content {
                self.lastMessageText = text
                self.lastMessageType = "image"
            }
        } else {
            // Все локальные сообщения скрыты — пользователь очистил чат
            self.lastMessageId = nil
            self.lastMessageText = nil
            self.lastMessageAt = nil
            self.lastMessageSenderId = nil
            self.lastMessageType = nil
        }
    }
}
