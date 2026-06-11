//
//  DatabaseService.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 17.03.2026.
//

import Foundation
import SwiftData

@MainActor
class DatabaseService {
    
    let modelContext: ModelContext
    
    init(context: ModelContext) {
        self.modelContext = context
    }
    
    func saveIncomingMessage(dto: RealtimeMessageDTO, currentUserId: String) throws {
        print("БД: 🔥 Начинаем сохранение сообщения \(dto.id) от \(dto.sender_id)")
        // Все UUID в lowercase — Postgres/Supabase хранит lowercase,
        // а Swift UUID.uuidString.lowercased() возвращает UPPERCASE
        let msgId = dto.id.uuidString.lowercased()
        let chatId = dto.chat_id.uuidString.lowercased()
        let senderId = dto.sender_id.uuidString.lowercased()
        
        var descriptor = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == msgId })
        descriptor.fetchLimit = 1
        
        if try modelContext.fetch(descriptor).isEmpty {
            let content = parseMessageContent(
                type: dto.content_type,
                text: dto.content_text,
                imageUrl: dto.content_image_url,
                thumbUrl: dto.content_thumb_url,
                width: dto.image_width,
                height: dto.image_height,
                blurHash: dto.content_blur_hash
            )
            
            let status = MessageStatus(rawValue: dto.status) ?? .sent
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = formatter.date(from: dto.created_at) ?? Date()
            
            let msgDB = MessageDB(
                id: msgId,
                chatId: chatId,
                senderId: senderId,
                replyToMessageId: dto.reply_to_message_id?.uuidString.lowercased(),
                threadRootId: dto.thread_root_id?.uuidString.lowercased(),
                content: content,
                createdAt: date,
                status: status
            )
            
            modelContext.insert(msgDB)
            
            let chatDesc = FetchDescriptor<ChatDB>(predicate: #Predicate { $0.id == chatId })
            if let chatDB = try modelContext.fetch(chatDesc).first {
                chatDB.lastMessageId = msgId
                if senderId != currentUserId {
                    chatDB.unreadCount += 1
                }
                chatDB.updateSnapshot(context: modelContext)
            }
            
            try modelContext.save()
            
            print("БД: ✅ Сообщение \(msgId) сохранено! Отправляем .newMessageSaved для \(chatId)")
            // Уведомляем main context о новом сообщении (chatId в lowercase)
            NotificationCenter.default.post(
                name: Notification.Name("newMessageSaved"),
                object: chatId,
                userInfo: ["eventType": "inserted"]
            )
        }
    }
    
    private func parseMessageContent(type: String, text: String?, imageUrl: String?, thumbUrl: String?, width: Double?, height: Double?, blurHash: String? = nil) -> MessageContent {
        if type == "text" {
            return .text(text ?? "")
        } else {
            let original = URL(string: imageUrl ?? "https://example.com")!
            let thumb = thumbUrl != nil ? URL(string: thumbUrl!) : nil
            return .image(imageURL: original, thumbURL: thumb, text: text, width: width, height: height, blurHash: blurHash)
        }
    }
    
    func applyMessageEvent(dto: MessageEventDTO) throws {
        let msgId = dto.message_id.uuidString.lowercased()
        let chatId = dto.chat_id.uuidString.lowercased()
        
        let fetchDesc = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == msgId })
        guard let msgDB = try modelContext.fetch(fetchDesc).first else { return }
        
        switch dto.event_type {
        case "deleted":
            msgDB.isHiddenLocally = true
        case "edited":
            if let newText = dto.new_text {
                msgDB.content = .text(newText)
            }
        default:
            break
        }
        
        try modelContext.save()
        // Уведомляем UI о том, что сообщение обновилось
        NotificationCenter.default.post(
            name: Notification.Name("newMessageSaved"),
            object: chatId,
            userInfo: ["eventType": dto.event_type]
        )
    }
}

extension Notification.Name {
    static let newMessageSaved = Notification.Name("newMessageSaved")
    static let newChatDetected = Notification.Name("newChatDetected")
    static let imageSavedToPhotos = Notification.Name("imageSavedToPhotos")
}
