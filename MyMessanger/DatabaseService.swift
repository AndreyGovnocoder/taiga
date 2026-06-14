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
        Log.debug(.db, "БД: 🔥 Начинаем сохранение сообщения \(dto.id)")
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

            let chatDesc = FetchDescriptor<ChatDB>(predicate: #Predicate { $0.id == chatId })
            let chatDB = try modelContext.fetch(chatDesc).first

            // «Очистить чат»: входящее старше серверной метки очистки не показываем (защита от
            // гонок ресинка). Нормальные новые сообщения всегда новее метки → показываются и
            // оживляют удалённый чат (через newChatDetected → fetchChats, last_message_at > deleted_at).
            if let clearedAt = chatDB?.clearedAt, date <= clearedAt {
                msgDB.isHiddenLocally = true
            }

            modelContext.insert(msgDB)

            if let chatDB {
                chatDB.lastMessageId = msgId
                // Клиентский инкремент только для НЕ-muted и НЕ скрытых: сервер инкрементит так же
                // (handle_new_message … and is_muted = false), иначе локальный счётчик/бейдж
                // разойдётся с серверным unread_count.
                if senderId != currentUserId && !chatDB.isMuted && !msgDB.isHiddenLocally {
                    chatDB.unreadCount += 1
                }
                chatDB.updateSnapshot(context: modelContext)
            }

            try modelContext.save()
            
            Log.debug(.db, "БД: ✅ Сообщение \(msgId) сохранено! Отправляем .newMessageSaved для \(chatId)")
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
            guard let original = SupabaseConfig.rewrittenURL(fromStored: imageUrl) else {
                // Битый/непарсимый URL картинки с сервера — деградируем в текст, а не крашимся.
                return .text(text ?? "")
            }
            let thumb = SupabaseConfig.rewrittenURL(fromStored: thumbUrl)
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
    /// Тап по пушу: открыть конкретный чат (object = chat_id, lowercase).
    /// Постится из AppDelegate.didReceive, обрабатывается ContentView (deep-link).
    static let openChatRequested = Notification.Name("openChatRequested")
}
