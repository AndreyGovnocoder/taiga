//
//  Mappers.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 10.03.2026.
//


import Foundation

extension UserDB {
    func toDomain() -> User {
        return User(id: self.id, phoneNumber: self.phoneNumber, name: self.name, nickname: self.nickname, avatar: self.avatarURL, isOnline: self.isOnline)
    }
}

extension User {
    func toDB() -> UserDB {
        return UserDB(id: self.id, phoneNumber: self.phoneNumber, name: self.name, nickname: self.nickname, avatarURL: self.avatar, isOnline: self.isOnline)
    }
}

extension MessageDB {
    func toDomain() -> Message {
        return Message(id: self.id, chatId: self.chatId, senderId: self.senderId, replyToMessageId: self.replyToMessageId, threadRootId: self.threadRootId, content: self.content, createdAt: self.createdAt, status: self.status)
    }
}

extension Message {
    func toDB() -> MessageDB {
        return MessageDB(id: self.id, chatId: self.chatId, senderId: self.senderId, replyToMessageId: self.replyToMessageId, threadRootId: self.threadRootId, content: self.content, createdAt: self.createdAt, status: self.status)
    }
}

extension ChatDB {
    func toDomain(participants: [User], lastMessage: Message?) -> Chat {
        return Chat(
            id: self.id,
            type: self.type,
            participants: participants,
            lastMessage: lastMessage,
            unreadCount: self.unreadCount,
            myRole: self.myRole,
            isMuted: self.isMuted,
            lastMessageText: self.lastMessageText,
            lastMessageAt: self.lastMessageAt,
            lastMessageSenderId: self.lastMessageSenderId,
            lastMessageType: self.lastMessageType
        )
    }
}

extension Chat {
    func toDB() -> ChatDB {
        let ids = self.participants.map { $0.id }
        let lastMsgId = self.lastMessage?.id
        return ChatDB(
            id: self.id,
            type: self.type,
            unreadCount: self.unreadCount,
            participantIds: ids,
            lastMessageId: lastMsgId,
            myRole: self.myRole,
            isMuted: self.isMuted,
            lastMessageText: self.lastMessageText,
            lastMessageAt: self.lastMessageAt,
            lastMessageSenderId: self.lastMessageSenderId,
            lastMessageType: self.lastMessageType
        )
    }
}
