//
//  models.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 10.03.2026.
//

import Foundation

struct User: Identifiable, Hashable {
    let id: String
    let phoneNumber: String
    var name: String
    var nickname: String
    var avatar: URL?
    var isOnline: Bool = false
    
    static let currentUserMock = User(id: "user_1", phoneNumber: "+79140384414", name: "Андрей", nickname: "goose", isOnline: true)
}
    
enum MessageContent: Sendable {
    case text(String)
    case image(imageURL: URL, thumbURL: URL?, text: String?, width: Double?, height: Double?, blurHash: String?)
    // TODO добавить case voice(audioURL: URL, duration: Int
}

nonisolated extension MessageContent: Codable, Hashable {}
    
enum MessageStatus: String, Codable {
    case sending
    case sent
    case delivered
    case read
    case failed
}

struct Message: Identifiable, Hashable {
    let id: String
    let chatId: String
    let senderId: String
    let replyToMessageId: String?
    let threadRootId: String?
    var content: MessageContent
    let createdAt: Date
    var status: MessageStatus
    
    var isCurrentUser: Bool {
        let currentId = SupabaseManager.shared.currentUserId ?? ""
        return senderId == currentId
    }
    
    /// Сообщение старше TTL (3 дня) — на сервере уже удалено или будет удалено
    var isExpiredOnServer: Bool {
        createdAt.addingTimeInterval(3 * 24 * 3600) < Date()
    }
    
    /// Можно ли удалить у всех (своё + в пределах TTL)
    var canDeleteForEveryone: Bool {
        isCurrentUser && !isExpiredOnServer
    }
    
    /// Можно ли редактировать (своё + в пределах TTL + только текст)
    var canEdit: Bool {
        guard isCurrentUser && !isExpiredOnServer else { return false }
        if case .text = content { return true }
        return false
    }
    
    static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.content == rhs.content
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(status)
    }
}

enum ChatType: Sendable, Hashable {
    case personal
    case group(name: String, avatarURL: URL?)
}

nonisolated extension ChatType: Codable {}

struct Chat: Identifiable, Hashable {
    var id: String
    let type: ChatType
    var participants: [User]
    var lastMessage: Message?
    var unreadCount: Int = 0
    var myRole: String = "member"
    var isMuted: Bool = false
    
    // MARK: - Snapshot последнего сообщения (для списка чатов без JOIN)
    var lastMessageText: String?
    var lastMessageAt: Date?
    var lastMessageSenderId: String?
    var lastMessageType: String?
    
    /// Draft-чат ещё не создан на сервере (id начинается с "draft_")
    var isDraft: Bool { id.hasPrefix("draft_") }
    
    /// ID целевого пользователя для draft личного чата
    var draftTargetUserId: String? {
        guard isDraft else { return nil }
        return String(id.dropFirst("draft_".count))
    }
    
    var isGroup: Bool {
        if case .group = type { return true }
        return false
    }
    
    var isAdmin: Bool {
        myRole == "admin"
    }
    
    var displayTitle: String {
        let currentId = SupabaseManager.shared.currentUserId ?? ""
        
        switch type {
        case .personal:
            return participants.first(where: { $0.id != currentId})?.name ?? "Неизвестно"
        case .group(name: let name, avatarURL: _):
            return name
        }
    }
    
    /// Превью для списка чатов: snapshot или lastMessage
    var previewText: String? {
        // Приоритет: lastMessage (если есть), иначе snapshot
        if let msg = lastMessage {
            switch msg.content {
            case .text(let text): return text
            case .image(_, _, let text, _, _, _): return text ?? "📷 Фото"
            }
        }
        if let snapType = lastMessageType, snapType == "image" {
            return lastMessageText?.isEmpty == false ? lastMessageText : "📷 Фото"
        }
        return lastMessageText
    }
    
    /// Дата последнего сообщения для сортировки
    var lastActivityDate: Date? {
        lastMessage?.createdAt ?? lastMessageAt
    }
}

// MARK: - ChatItem (обёртка для TiledView)

/// Обёртка Message + флаг разделителя дня для ListDataSource.
/// showDateSeparator включён в Equatable, чтобы UICollectionView
/// перерисовывал ячейку при смене статуса разделителя (удаление сообщения).
struct ChatItem: Identifiable, Equatable {
    let message: Message
    let showDateSeparator: Bool
    let repliedMessage: Message?
    let repliedSenderName: String?
    let threadCount: Int?
    let senderName: String?
    let senderAvatar: URL?
    let isGroupChat: Bool
    let isFirstFromSender: Bool
    let isLastFromSender: Bool
    
    var id: String { message.id }
    
    static func == (lhs: ChatItem, rhs: ChatItem) -> Bool {
        lhs.message == rhs.message
        && lhs.showDateSeparator == rhs.showDateSeparator
        && lhs.repliedMessage?.id == rhs.repliedMessage?.id
        && lhs.repliedSenderName == rhs.repliedSenderName
        && lhs.threadCount == rhs.threadCount
        && lhs.senderName == rhs.senderName
        && lhs.senderAvatar == rhs.senderAvatar
        && lhs.isGroupChat == rhs.isGroupChat
        && lhs.isFirstFromSender == rhs.isFirstFromSender
        && lhs.isLastFromSender == rhs.isLastFromSender
    }
}

// MARK: - Selection State (FluidGroup TiledView)

@Observable
final class SharedSelectionState {
    var isSelectionMode: Bool = false
    var selectedIds: Set<String> = []
    var deletingIds: Set<String> = []
}

// MARK: - ThreadItem (обёртка для TiledView в ветке)

/// Обёртка Message для ListDataSource в ThreadOverlayView.
/// Содержит разделитель по дате, но без thread counts.
struct ThreadItem: Identifiable, Equatable {
    let message: Message
    let showDateSeparator: Bool
    let repliedMessage: Message?
    let repliedSenderName: String?
    let senderName: String?
    let senderAvatar: URL?
    
    var id: String { message.id }
    
    static func == (lhs: ThreadItem, rhs: ThreadItem) -> Bool {
        lhs.message == rhs.message
        && lhs.showDateSeparator == rhs.showDateSeparator
        && lhs.repliedMessage?.id == rhs.repliedMessage?.id
        && lhs.senderName == rhs.senderName
        && lhs.senderAvatar == rhs.senderAvatar
    }
}
