//
//  SupabaseChatService.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 11.03.2026.
//


import Foundation
import SwiftData
import Supabase
import UIKit

@MainActor
class SupabaseChatService: ChatServiceProtocol {

    private let client = SupabaseManager.shared.client
    
    /// Принудительное переподключение realtime (после сна / выхода из фона)
    func reconnectRealtime() async {
        client.realtimeV2.disconnect()
        try? await Task.sleep(for: .milliseconds(300))
        await client.realtimeV2.connect()
        print("СЕРВЕР: Realtime переподключен")
    }
    
    func fetchChats(context: ModelContext) async throws -> [Chat] {
        let session = try await client.auth.session
        let myUserId = session.user.id
        
        print("СЕРВЕР: Мой реальный ID: \(myUserId.uuidString.lowercased())")
        
        let myParticipants: [ChatParticipantDTO] = try await client
            .from("chat_participants")
            .select()
            .eq("user_id", value: myUserId)
            .execute()
            .value
        
        print("СЕРВЕР: Найдено чатов для меня: \(myParticipants.count)")
        
        let chatIds = myParticipants.map { $0.chat_id }
        
        if chatIds.isEmpty {
            print("СЕРВЕР: Нет чатов для меня")
            return []
        }
        
        let chatsDTO: [ChatDTO] = try await client
            .from("chats")
            .select()
            .in("id", values: chatIds)
            .execute()
            .value
        
        let allParticipants: [ChatParticipantDTO] = try await client
            .from("chat_participants")
            .select()
            .in("chat_id", values: chatIds)
            .execute()
            .value
        
        let userIds = Array(Set(allParticipants.map { $0.user_id }))
        
        let usersDTO: [UserDTO] = try await client
            .from("users")
            .select()
            .in("id", values: userIds)
            .execute()
            .value
        
        for uDTO in usersDTO {
            let userDB = UserDB(
                id: uDTO.id.uuidString.lowercased(),
                phoneNumber: uDTO.phone_number ?? "",
                name: uDTO.name,
                nickname: uDTO.nickname ?? "",
                avatarURL: uDTO.avatar_url != nil ? URL(string: uDTO.avatar_url!) : nil,
                isOnline: uDTO.is_online
            )
            context.insert(userDB)
        }
        
        for cDTO in chatsDTO {
            let pIds = allParticipants.filter { $0.chat_id == cDTO.id }.map { $0.user_id.uuidString.lowercased() }
            let myParticipant = myParticipants.first { $0.chat_id == cDTO.id }
            let unread = myParticipant?.unread_count ?? 0
            let role = myParticipant?.role ?? "member"
            let muted = myParticipant?.is_muted ?? false
            
            let type: ChatType = cDTO.type == "personal"
            ? .personal
            : .group(name: cDTO.name ?? "Группа", avatarURL: cDTO.avatar_url != nil ? URL(string: cDTO.avatar_url!) : nil)
            
            let chatDB = ChatDB(
                id: cDTO.id.uuidString.lowercased(),
                type: type,
                unreadCount: unread,
                participantIds: pIds,
                lastMessageId: cDTO.last_message_id?.uuidString.lowercased(),
                myRole: role,
                isMuted: muted,
                lastMessageText: cDTO.last_message_text,
                lastMessageAt: cDTO.last_message_at,
                lastMessageSenderId: cDTO.last_message_sender_id?.uuidString.lowercased(),
                lastMessageType: cDTO.last_message_type
            )
            context.insert(chatDB)
        }
        
        // Snapshot последнего сообщения уже в chats (денормализация) —
        // отдельный запрос к messages НЕ нужен
        
        try? context.save()
        
        // Пересчитываем snapshot из локальных сообщений (с учётом isHiddenLocally).
        // Серверный snapshot мог показать сообщение, которое пользователь локально скрыл.
        let descriptor = FetchDescriptor<ChatDB>()
        let chatDBs = (try? context.fetch(descriptor)) ?? []
        
        for chatDB in chatDBs {
            chatDB.updateSnapshot(context: context)
        }
        try? context.save()
        
        var domainChats = [Chat]()
        
        for chatDB in chatDBs {
            if !chatIds.map({ $0.uuidString.lowercased() }).contains(chatDB.id) { continue }
            
            var participants = [User]()
            for userId in chatDB.participantIds {
                let userDesc = FetchDescriptor<UserDB>(predicate: #Predicate { $0.id == userId })
                if let userDB = try? context.fetch(userDesc).first {
                    participants.append(userDB.toDomain())
                }
            }
            
            domainChats.append(chatDB.toDomain(participants: participants, lastMessage: nil))
        }
        
        return domainChats
    }
    
    func fetchMessages(for chatId: String, limit: Int = 50, before date: Date? = nil, context: ModelContext) async throws -> Int {
        var query = client.from("messages").select().eq("chat_id", value: chatId)
        
        if let validDate = date {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let dateStr = formatter.string(from: validDate)
            query = query.lt("created_at", value: dateStr)
        }
        
        let messagesDTO: [MessageDTO] = try await query
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        
        for dto in messagesDTO {
            let msgId = dto.id.uuidString.lowercased()
            let fetchDescriptor = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == msgId })
            let existing = try? context.fetch(fetchDescriptor).first
            
            if existing == nil {
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
                
                let msgDB = MessageDB(
                    id: msgId,
                    chatId: dto.chat_id.uuidString.lowercased(),
                    senderId: dto.sender_id.uuidString.lowercased(),
                    replyToMessageId: dto.reply_to_message_id?.uuidString.lowercased(),
                    threadRootId: dto.thread_root_id?.uuidString.lowercased(),
                    content: content,
                    createdAt: dto.created_at,
                    status: status
                )
                context.insert(msgDB)
            } else {
                existing?.status = MessageStatus(rawValue: dto.status) ?? existing!.status
                // Обновляем threadRootId (мог быть nil на оптимистичном сообщении)
                if existing?.threadRootId == nil, let serverThreadRoot = dto.thread_root_id {
                    existing?.threadRootId = serverThreadRoot.uuidString.lowercased()
                }
            }
        }
        
        try? context.save()
        
        return messagesDTO.count
    }
    
    func sendMessage(chatId: String, content: MessageContent, replyToMessageId: String?, threadRootId: String? = nil, context: ModelContext) async throws {
        let session = try await client.auth.session
        let myUserId = session.user.id
        
        // Вычисляем threadRootId: переданный напрямую ИЛИ из reply_to
        var localThreadRootId: String? = threadRootId
        if localThreadRootId == nil, let replyId = replyToMessageId {
            let replyPredicate = #Predicate<MessageDB> { msg in msg.id == replyId }
            var replyDesc = FetchDescriptor<MessageDB>(predicate: replyPredicate)
            replyDesc.fetchLimit = 1
            if let parentMsg = try? context.fetch(replyDesc).first {
                localThreadRootId = parentMsg.threadRootId ?? parentMsg.id
            }
        }
        
        let localMsgId = UUID()
        let localMsgDB = MessageDB(
            id: localMsgId.uuidString.lowercased(),
            chatId: chatId,
            senderId: myUserId.uuidString.lowercased(),
            replyToMessageId: replyToMessageId,
            content: content,
            createdAt: Date(),
            status: .sending
        )
        localMsgDB.threadRootId = localThreadRootId
        context.insert(localMsgDB)
        try? context.save()
        
        var contentType = "text"
        var contentText: String? = nil
        
        switch content {
            case .text(let text):
                contentType = "text"
                contentText = text
            case .image(_, _, let text, _, _, _):
                contentType = "image"
                contentText = text
        }
        
        guard let chatUUID = UUID(uuidString: chatId) else {
            throw NSError(domain: "ChatService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid chatId: \(chatId)"])
        }
        
        let sendDTO = MessageInsertDTO(
            id: localMsgId,
            chat_id: chatUUID,
            sender_id: myUserId,
            reply_to_message_id: replyToMessageId != nil ? UUID(uuidString: replyToMessageId!) : nil,
            thread_root_id: localThreadRootId != nil ? UUID(uuidString: localThreadRootId!) : nil,
            content_type: contentType,
            content_text: contentText,
            content_image_url: nil,
            content_thumb_url: nil,
            content_blur_hash: nil,
            image_width: nil,
            image_height: nil,
            status: "sent"
        )
        
        do {
            try await client
                .from("messages")
                .insert(sendDTO)
                .execute()
            
            localMsgDB.status = .sent
            
            // Забираем thread_root_id с сервера (выставлен триггером)
            let serverRows: [MessageDTO] = try await client
                .from("messages")
                .select()
                .eq("id", value: localMsgId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            if let serverMsg = serverRows.first {
                localMsgDB.threadRootId = serverMsg.thread_root_id?.uuidString.lowercased()
            }
            
            let chatDesc = FetchDescriptor<ChatDB>(predicate: #Predicate { $0.id == chatId })
            if let chatDB = try? context.fetch(chatDesc).first {
                chatDB.lastMessageId = localMsgId.uuidString.lowercased()
            }
            
            try? context.save()
            
        } catch {
            let errorString = String(describing: error)
            if errorString.contains("messages_reply_to_message_id_fkey") {
                print("СЕРВЕР: Родительского сообщения больше нет на сервере. Отправляем как обычное.")
                
                let fallbackDTO = MessageInsertDTO(
                    id: localMsgId,
                    chat_id: chatUUID,
                    sender_id: myUserId,
                    reply_to_message_id: nil,
                    thread_root_id: localThreadRootId != nil ? UUID(uuidString: localThreadRootId!) : nil,
                    content_type: contentType,
                    content_text: contentText,
                    content_image_url: nil,
                    content_thumb_url: nil,
                    content_blur_hash: nil,
                    image_width: nil,
                    image_height: nil,
                    status: "sent"
                )
                
                do {
                    try await client
                        .from("messages")
                        .insert(fallbackDTO)
                        .execute()
                    localMsgDB.status = .sent
                    localMsgDB.replyToMessageId = nil
                    try? context.save()
                    return
                } catch {
                    localMsgDB.status = .failed
                    try? context.save()
                    throw error
                }
            }
            
            localMsgDB.status = .failed
            try? context.save()
            throw error
        }
    }
    
    // MARK: - Split Send (Фаза 1 + Фаза 2)
    
    /// Фаза 1: мгновенная вставка MessageDB в SwiftData (status: .sending).
    /// Возвращает ID созданного сообщения. Не делает сетевых запросов.
    func insertLocalMessage(chatId: String, content: MessageContent, replyToMessageId: String?, threadRootId: String? = nil, context: ModelContext) throws -> String {
        guard let currentUserId = SupabaseManager.shared.currentUserId else {
            throw URLError(.userAuthenticationRequired)
        }
        
        // Вычисляем threadRootId: переданный напрямую ИЛИ из reply_to
        var localThreadRootId: String? = threadRootId
        if localThreadRootId == nil, let replyId = replyToMessageId {
            let replyPredicate = #Predicate<MessageDB> { msg in msg.id == replyId }
            var replyDesc = FetchDescriptor<MessageDB>(predicate: replyPredicate)
            replyDesc.fetchLimit = 1
            if let parentMsg = try? context.fetch(replyDesc).first {
                localThreadRootId = parentMsg.threadRootId ?? parentMsg.id
            }
        }
        
        let localMsgId = UUID().uuidString.lowercased()
        let localMsgDB = MessageDB(
            id: localMsgId,
            chatId: chatId,
            senderId: currentUserId,
            replyToMessageId: replyToMessageId,
            content: content,
            createdAt: Date(),
            status: .sending
        )
        localMsgDB.threadRootId = localThreadRootId
        context.insert(localMsgDB)
        
        // Обновляем lastMessageId чата оптимистично
        let chatDesc = FetchDescriptor<ChatDB>(predicate: #Predicate { $0.id == chatId })
        if let chatDB = try? context.fetch(chatDesc).first {
            chatDB.lastMessageId = localMsgId
        }
        
        try? context.save()
        return localMsgId
    }
    
    /// Фаза 2: отправка ранее вставленного сообщения на Supabase.
    /// При успехе: status → .sent. При ошибке сети: status остаётся .sending (для авторетрая).
    func deliverMessage(messageId: String, context: ModelContext) async throws {
        var descriptor = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == messageId })
        descriptor.fetchLimit = 1
        guard let localMsgDB = try? context.fetch(descriptor).first else { return }
        
        // Уже доставлено — skip
        guard localMsgDB.status == .sending else { return }
        
        let session = try await client.auth.session
        let myUserId = session.user.id
        
        var contentType = "text"
        var contentText: String? = nil
        
        switch localMsgDB.content {
        case .text(let text):
            contentType = "text"
            contentText = text
        case .image(_, _, let text, _, _, _):
            contentType = "image"
            contentText = text
        }
        
        let chatId = localMsgDB.chatId
        
        // Draft-чат — пропускаем доставку, материализация произойдёт в ChatViewModel
        if chatId.hasPrefix("draft_") {
            print("DELIVER: Пропуск draft-сообщения \(messageId) (chatId: \(chatId))")
            return
        }
        
        guard let msgUUID = UUID(uuidString: messageId),
              let chatUUID = UUID(uuidString: chatId) else {
            print("DELIVER: Invalid UUID — messageId: \(messageId), chatId: \(chatId)")
            throw NSError(domain: "ChatService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid UUID in deliverMessage"])
        }
        
        let sendDTO = MessageInsertDTO(
            id: msgUUID,
            chat_id: chatUUID,
            sender_id: myUserId,
            reply_to_message_id: localMsgDB.replyToMessageId != nil ? UUID(uuidString: localMsgDB.replyToMessageId!) : nil,
            thread_root_id: localMsgDB.threadRootId != nil ? UUID(uuidString: localMsgDB.threadRootId!) : nil,
            content_type: contentType,
            content_text: contentText,
            content_image_url: nil,
            content_thumb_url: nil,
            content_blur_hash: nil,
            image_width: nil,
            image_height: nil,
            status: "sent",
            created_at: localMsgDB.createdAt
        )
        
        do {
            try await client
                .from("messages")
                .upsert(sendDTO, onConflict: "id", ignoreDuplicates: true)
                .execute()
            
            localMsgDB.status = .sent
            
            // Забираем thread_root_id с сервера (выставлен триггером)
            let serverRows: [MessageDTO] = try await client
                .from("messages")
                .select()
                .eq("id", value: messageId)
                .limit(1)
                .execute()
                .value
            if let serverMsg = serverRows.first {
                localMsgDB.threadRootId = serverMsg.thread_root_id?.uuidString.lowercased()
            }
            
            try? context.save()
            print("DELIVER: Сообщение \(messageId) успешно доставлено")
            
        } catch {
            let errorString = String(describing: error)
            if errorString.contains("messages_reply_to_message_id_fkey") {
                print("DELIVER: Родительского сообщения нет. Отправляем без реплая.")
                
                let fallbackDTO = MessageInsertDTO(
                    id: msgUUID,
                    chat_id: chatUUID,
                    sender_id: myUserId,
                    reply_to_message_id: nil,
                    thread_root_id: localMsgDB.threadRootId != nil ? UUID(uuidString: localMsgDB.threadRootId!) : nil,
                    content_type: contentType,
                    content_text: contentText,
                    content_image_url: nil,
                    content_thumb_url: nil,
                    content_blur_hash: nil,
                    image_width: nil,
                    image_height: nil,
                    status: "sent",
                    created_at: localMsgDB.createdAt
                )
                
                do {
                    try await client.from("messages").upsert(fallbackDTO, onConflict: "id", ignoreDuplicates: true).execute()
                    localMsgDB.status = .sent
                    localMsgDB.replyToMessageId = nil
                    try? context.save()
                    return
                } catch {
                    // Не меняем статус на .failed — оставляем .sending для авторетрая
                    print("DELIVER: Ошибка fallback-отправки: \(error.localizedDescription)")
                    throw error
                }
            }
            
            // Не меняем статус на .failed — оставляем .sending для авторетрая
            print("DELIVER: Ошибка доставки (status остаётся .sending): \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Массовый retry всех сообщений со статусом .sending.
    /// Вызывается при восстановлении сети и при открытии приложения.
    func retryPendingMessages(context: ModelContext) async {
        let descriptor = FetchDescriptor<MessageDB>(
            predicate: #Predicate { $0.statusRaw == "sending" },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        
        guard let pendingMessages = try? context.fetch(descriptor), !pendingMessages.isEmpty else {
            return
        }
        
        print("RETRY: Найдено \(pendingMessages.count) недоставленных сообщений")
        
        for msgDB in pendingMessages {
            do {
                try await deliverMessage(messageId: msgDB.id, context: context)
            } catch {
                print("RETRY: Не удалось доставить \(msgDB.id): \(error.localizedDescription)")
                // Продолжаем с остальными
            }
        }
    }
    
    func retryMessage(_ message: Message, context: ModelContext) async throws {
        let msgId = message.id
        var descriptor = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == msgId })
        descriptor.fetchLimit = 1
        
        guard let localMsgDB = try? context.fetch(descriptor).first else { return }
        
        // Draft-чат — пропускаем retry, материализация произойдёт в ChatViewModel
        if localMsgDB.chatId.hasPrefix("draft_") {
            print("RETRY: Пропуск draft-сообщения \(msgId)")
            return
        }
        
        localMsgDB.status = .sending
        
        let chatId = localMsgDB.chatId
        
        try? context.save()
        
        guard let msgUUID = UUID(uuidString: message.id),
              let chatUUID = UUID(uuidString: chatId),
              let senderUUID = UUID(uuidString: message.senderId) else { return }
        
        switch message.content {
        case .text(let text):
            // Retry текстового сообщения
            let sendDTO = MessageInsertDTO(
                id: msgUUID,
                chat_id: chatUUID,
                sender_id: senderUUID,
                reply_to_message_id: message.replyToMessageId != nil ? UUID(uuidString: message.replyToMessageId!) : nil,
                thread_root_id: nil,
                content_type: "text",
                content_text: text,
                content_image_url: nil,
                content_thumb_url: nil,
                content_blur_hash: nil,
                image_width: nil,
                image_height: nil,
                status: "sent",
                created_at: message.createdAt
            )
            
            do {
                try await client.from("messages").insert(sendDTO).execute()
                localMsgDB.status = .sent
                try? context.save()
            } catch {
                let errorString = String(describing: error)
                if errorString.contains("messages_reply_to_message_id_fkey") {
                    print("СЕРВЕР/RETRY: Родительского сообщения нет. Отправляем без реплая.")
                    var fallback = sendDTO
                    fallback.created_at = message.createdAt
                    let fallbackDTO = MessageInsertDTO(
                        id: sendDTO.id, chat_id: sendDTO.chat_id, sender_id: sendDTO.sender_id,
                        reply_to_message_id: nil, thread_root_id: nil, content_type: "text", content_text: text,
                        content_image_url: nil, content_thumb_url: nil, content_blur_hash: nil,
                        image_width: nil, image_height: nil, status: "sent", created_at: message.createdAt
                    )
                    do {
                        try await client.from("messages").insert(fallbackDTO).execute()
                        localMsgDB.status = .sent
                        localMsgDB.replyToMessageId = nil
                        try? context.save()
                        return
                    } catch {
                        localMsgDB.status = .failed
                        try? context.save()
                        throw error
                    }
                }
                localMsgDB.status = .failed
                try? context.save()
                throw error
            }
            
        case .image(let imageURL, let thumbURL, let text, let width, let height, let blurHash):
            let progressManager = UploadProgressManager.shared
            progressManager.setProgress(0.05, for: msgId)
            
            do {
                let remoteOriginalURL: URL
                let remoteThumbURL: URL?
                
                // Если URL уже remote (файлы успешно загружены ранее) — пропускаем upload
                if imageURL.scheme == "https" {
                    print("СЕРВЕР/RETRY: Файлы уже в Storage, пропускаем upload. Только upsert в messages.")
                    remoteOriginalURL = imageURL
                    remoteThumbURL = thumbURL
                    progressManager.setProgress(0.7, for: msgId)
                } else {
                    // Файлы ещё локальные — нужен upload
                    let originalKey = imageURL.lastPathComponent
                    let thumbKey = thumbURL?.lastPathComponent ?? ""
                    
                    guard let originalData = await LocalCache.shared.load(forKey: originalKey) else {
                        print("СЕРВЕР/RETRY: Оригинал не найден в кэше — помечаем как .failed")
                        progressManager.removeProgress(for: msgId)
                        localMsgDB.status = .failed
                        try? context.save()
                        return
                    }
                    
                    let thumbData = await LocalCache.shared.load(forKey: thumbKey) ?? originalData
                    let fileName = "\(msgId).\(originalData.isHEIC ? "heic" : "jpg")"
                    let thumbFileName = "\(msgId)_thumb.jpg"
                    
                    progressManager.setProgress(0.15, for: msgId)
                    
                    // Загружаем оригинал и thumb — каждый независимо (устойчивость к частичному сбою)
                    async let originalTask = self.uploadImage(data: originalData, fileName: fileName)
                    async let thumbTask = self.uploadImage(data: thumbData, fileName: thumbFileName)
                    let (uploadedOriginal, uploadedThumb) = try await (originalTask, thumbTask)
                    
                    // Кэшируем под remote-ключом
                    await LocalCache.shared.saveImageData(originalData, forKey: uploadedOriginal.lastPathComponent)
                    await LocalCache.shared.saveImageData(thumbData, forKey: uploadedThumb.lastPathComponent)
                    
                    remoteOriginalURL = uploadedOriginal
                    remoteThumbURL = uploadedThumb
                    progressManager.setProgress(0.7, for: msgId)
                }
                
                let sendDTO = MessageInsertDTO(
                    id: UUID(uuidString: message.id)!,
                    chat_id: UUID(uuidString: message.chatId)!,
                    sender_id: UUID(uuidString: message.senderId)!,
                    reply_to_message_id: message.replyToMessageId != nil ? UUID(uuidString: message.replyToMessageId!) : nil,
                    thread_root_id: nil,
                    content_type: "image",
                    content_text: text,
                    content_image_url: remoteOriginalURL.absoluteString,
                    content_thumb_url: remoteThumbURL?.absoluteString,
                    content_blur_hash: blurHash,
                    image_width: width,
                    image_height: height,
                    status: "sent",
                    created_at: message.createdAt
                )
                
                // Fix 3: Сохраняем remote URL в MessageDB ДО INSERT в Supabase.
                // Если INSERT упадёт — retry увидит https:// URL и пропустит upload.
                localMsgDB.content = .image(imageURL: remoteOriginalURL, thumbURL: remoteThumbURL, text: text, width: width, height: height, blurHash: blurHash)
                try? context.save()
                
                try await client.from("messages")
                    .upsert(sendDTO, onConflict: "id", ignoreDuplicates: true)
                    .execute()
                
                localMsgDB.status = .sent
                try? context.save()
                
                progressManager.setProgress(1.0, for: msgId)
                try? await Task.sleep(nanoseconds: 300_000_000)
                progressManager.removeProgress(for: msgId)
                
                NotificationCenter.default.post(name: .messageStatusChanged, object: message.chatId)
                
            } catch {
                progressManager.removeProgress(for: msgId)
                localMsgDB.status = .failed
                try? context.save()
                NotificationCenter.default.post(name: .messageStatusChanged, object: message.chatId)
                throw error
            }
        }
    }

    
    /*
    func subscribeToMessages(chatId: String, context: ModelContext, onNewMessage: @escaping @MainActor (MessageDB) -> Void) async throws {
        let channelName = "chat_\(chatId)_\(UUID().uuidString.lowercased())"
        let channel = client.channel(channelName)
        let insertions = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "messages",
            filter: .eq("chat_id", value: chatId)
        )
        
        try await channel.subscribeWithError()
        print("СЕРВЕР: Подписались на реалтайм чата \(chatId)")
        
        defer {
            Task {
                await channel.unsubscribe()
                await client.removeChannel(channel)
                print("СЕРВЕР: Отписались от реалтайм чата \(chatId)")
            }
        }
        
        for await insert in insertions {
            do {
                let dto = try insert.record.decode(as: RealtimeMessageDTO.self)
                let msgId = dto.id.uuidString.lowercased()
                
                let fetchDescriptor = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == msgId })
                let existing = try? context.fetch(fetchDescriptor).first
                
                if existing == nil {
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
                        chatId: dto.chat_id.uuidString.lowercased(),
                        senderId: dto.sender_id.uuidString.lowercased(),
                        replyToMessageId:  dto.reply_to_message_id?.uuidString.lowercased(),
                        threadRootId: dto.thread_root_id?.uuidString.lowercased(),
                        content: content,
                        createdAt: date,
                        status: status
                    )
                    
                    context.insert(msgDB)
                    onNewMessage(msgDB)
                    
                    let chatDesc = FetchDescriptor<ChatDB>(predicate: #Predicate { $0.id == dto.chat_id.uuidString.lowercased() })
                    if let chatDB = try? context.fetch(chatDesc).first {
                        chatDB.lastMessageId = msgId
                    }
                    
                    try? context.save()
                    print("СЕРВЕР: УСПЕХ! Получено новое сообщение по сокету: \(dto.content_text ?? "медиа")")
                }
            } catch {
                print("СЕРВЕР: ОШИБКА декодирования реалтайм сообщения: \(error)")
            }
        }
    }
    */
    
    func fetchLocalChats(context: ModelContext) throws -> [Chat] {
        guard let currentUserId = SupabaseManager.shared.currentUserId else {
            return[]
        }
        
        let descriptor = FetchDescriptor<ChatDB>()
        let allChatDBs = (try? context.fetch(descriptor)) ?? []
        
        let myChatDBs = allChatDBs.filter { $0.participantIds.contains(currentUserId) }
        
        var domainChats = [Chat]()
        
        for chatDB in myChatDBs {
            var participants = [User]()
            for userId in chatDB.participantIds {
                let userDesc = FetchDescriptor<UserDB>(predicate: #Predicate { $0.id == userId })
                if let userDB = try? context.fetch(userDesc).first {
                    participants.append(userDB.toDomain())
                }
            }
            
            domainChats.append(chatDB.toDomain(participants: participants, lastMessage: nil))
        }
        
        return domainChats.sorted { ($0.lastActivityDate ?? Date.distantPast) > ($1.lastActivityDate ?? Date.distantPast) }
    }
    
    func subscribeToAllChats(container: ModelContainer) async throws {
        let currentUserId = (SupabaseManager.shared.currentUserId ?? "").lowercased()
        
        let channel = client.channel("global_messages")
        
        // AsyncStream — регистрируем подписки ДО subscribe (требование SDK)
        let messageInserts = channel.postgresChange(
            InsertAction.self, schema: "public", table: "messages"
        )
        let messageEventChanges = channel.postgresChange(
            AnyAction.self, schema: "public", table: "message_events"
        )
        
        try await channel.subscribeWithError()
        print("СЕРВЕР DEBUG: Подписались на канал global_messages!")
        
        // Cleanup при завершении (отмена задачи, ошибка, etc.)
        defer {
            Task {
                await channel.unsubscribe()
                await client.removeChannel(channel)
                print("СЕРВЕР DEBUG: Отписались от глобального канала")
            }
        }
        
        // Параллельно слушаем оба стрима — for await выполняется на MainActor,
        // decode происходит внутри SDK до передачи в стрим — нет nonisolated проблемы
        await withTaskGroup(of: Void.self) { group in
            
            // MARK: - Новые сообщения (INSERT в messages)
            group.addTask { @MainActor in
                for await insert in messageInserts {
                    print("СЕРВЕР DEBUG: 🌐 ПОЛУЧЕН СИГНАЛ В messages!")
                    do {
                        let dto = try insert.record.decode(as: RealtimeMessageDTO.self)
                        
                        let senderId = dto.sender_id.uuidString.lowercased()
                        let chatId = dto.chat_id.uuidString.lowercased()
                        
                        guard senderId != currentUserId else { continue }
                        
                        let context = container.mainContext
                        let desc = FetchDescriptor<ChatDB>(predicate: #Predicate { $0.id == chatId })
                        let isKnown = (try? context.fetchCount(desc)) ?? 0 > 0
                        
                        let dbWorker = DatabaseService(context: context)
                        try? dbWorker.saveIncomingMessage(dto: dto, currentUserId: currentUserId)
                        
                        if !isKnown {
                            print("СЕРВЕР: Новый чат обнаружен: \(chatId). Перезагружаем список.")
                            NotificationCenter.default.post(name: Notification.Name("newChatDetected"), object: nil)
                        }
                    } catch {
                        print("СЕРВЕР DEBUG: Ошибка парсинга сообщения: \(error)")
                    }
                }
            }
            
            // MARK: - События сообщений (INSERT/UPDATE в message_events — удаление/редактирование)
            group.addTask { @MainActor in
                for await action in messageEventChanges {
                    print("СЕРВЕР DEBUG: 🌐 ПОЛУЧЕН СИГНАЛ В message_events!")
                    do {
                        let dto: MessageEventDTO
                        switch action {
                        case .insert(let insertAction):
                            dto = try insertAction.record.decode(as: MessageEventDTO.self)
                        case .update(let updateAction):
                            dto = try updateAction.record.decode(as: MessageEventDTO.self)
                        default:
                            continue
                        }
                        
                        let actorId = dto.actor_id.uuidString.lowercased()
                        let chatId = dto.chat_id.uuidString.lowercased()
                        
                        guard actorId != currentUserId else { continue }
                        
                        let context = container.mainContext
                        let desc = FetchDescriptor<ChatDB>(predicate: #Predicate { $0.id == chatId })
                        let isKnown = (try? context.fetchCount(desc)) ?? 0 > 0
                        
                        if isKnown {
                            let dbWorker = DatabaseService(context: context)
                            try? dbWorker.applyMessageEvent(dto: dto)
                        }
                    } catch {
                        print("СЕРВЕР DEBUG: Ошибка парсинга события: \(error)")
                    }
                }
            }
        }
    }
    
    func markChatAsRead(chatId: String, context: ModelContext) async throws {
        // Draft-чат — нечего отмечать
        guard let chatUUID = UUID(uuidString: chatId) else { return }
        
        let session  = try await client.auth.session
        let myUserId = session.user.id
        
        let fetchDescriptor = FetchDescriptor<ChatDB>(predicate: #Predicate { $0.id == chatId })
        if let chatDB = try? context.fetch(fetchDescriptor).first {
            chatDB.unreadCount = 0
            try? context.save()
        }
        
        try await client
            .from("chat_participants")
            .update(UpdateUnreadDTO(unread_count: 0))
            .eq("chat_id", value: chatUUID)
            .eq("user_id", value: myUserId)
            .execute()
    }
    
    func uploadImage(data: Data, fileName: String) async throws -> URL {
        let bucketName = "chat_media"
        
        let contentType = fileName.lowercased().hasSuffix("png") ? "image/png" : "image/jpeg"
        
        _ = try await client.storage
            .from(bucketName)
            .upload(
                fileName,
                data: data,
                options: FileOptions(contentType: contentType)
            )
        
        let publicURL = try client.storage
            .from(bucketName)
            .getPublicURL(path: fileName)
        
        print("СЕРВЕР: Фото успешно загружено! URL: \(publicURL.absoluteString)")
        return publicURL
    }
    
    func deleteMessage(_ message: Message, context: ModelContext) async throws {
        let msgId = message.id
        let chatId = message.chatId
        
        try await client
            .from("messages")
            .delete()
            .eq("id", value: message.id)
            .execute()
        
        if case .image(let url, let thumbURL, _, _, _, _) = message.content {
            let fileName = url.lastPathComponent
            var pathsToRemove = [fileName]
            
            Task {
                await LocalCache.shared.delete(forKey: fileName)
            }
            
            if let thumbName = thumbURL?.lastPathComponent {
                pathsToRemove.append(thumbName)
                Task {
                    await LocalCache.shared.delete(forKey: thumbName)
                }
            }
            
            do {
                _ = try await client.storage.from("chat_media").remove(paths: [fileName])
                print("СЕРВЕР: Фотография и миниатюра удалены из Supabase Storage")
            } catch {
                print("СЕРВЕР: Ошибка удаления фото из Supabase Storage: \(error.localizedDescription)")
            }
            
            await LocalCache.shared.delete(forKey: fileName)
        }
        
        let msgDesc = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == msgId })
        if let dbMessage = try? context.fetch(msgDesc).first {
            context.delete(dbMessage)
        }
        
        // Локальное обновление для оптимистичного UI
        let chatDesc = FetchDescriptor<ChatDB>(predicate: #Predicate { $0.id == chatId })
        if let chatDB = try? context.fetch(chatDesc).first {
            chatDB.updateSnapshot(context: context)
        }
        
        try? context.save()
    }
    
    func deleteMessages(_ messages: [Message], context: ModelContext) async throws {
        guard !messages.isEmpty else { return }
        
        let chatId = messages.first!.chatId
        let cId = chatId
        let messageIds = messages.map { $0.id }
        
        let chatDesc = FetchDescriptor<ChatDB>(predicate: #Predicate { $0.id == cId })
        let chatDB = try? context.fetch(chatDesc).first
        
        let msgDesc = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.chatId == cId })
        if let allMsgs = try? context.fetch(msgDesc) {
            let msgsToDelete = allMsgs.filter { messageIds.contains($0.id) }
            for dbMsg in msgsToDelete {
                context.delete(dbMsg)
            }
            
            // Локальное обновление для оптимистичного UI
            if let chat = chatDB {
                chat.updateSnapshot(context: context)
            }
        }
        
        try? context.save()
        
        Task {
            do {
                _ = try await self.client
                    .from("messages")
                    .delete()
                    .in("id", values: messageIds)
                    .execute()
                
                var fileNames = [String]()
                for msg in messages {
                    if case .image(let url, let thumbURL, _, _, _, _) = msg.content {
                        fileNames.append(url.lastPathComponent)
                        await LocalCache.shared.delete(forKey: url.lastPathComponent)
                        
                        if let thumbName = thumbURL?.lastPathComponent {
                            fileNames.append(thumbName)
                            await LocalCache.shared.delete(forKey: thumbName)
                        }
                    }
                }
                
                if !fileNames.isEmpty {
                    _ = try? await self.client.storage.from("chat_media").remove(paths: fileNames)
                        
                }
                
                print("СЕРВЕР: Фоновое пакетное удаление (\(messages.count) шт/) успешно завершено")
            } catch {
                print("СЕРВЕР: Ошибка фонового массового удаления: \(error.localizedDescription)")
            }
        }
    }
    
    func sendMediaMessages(chatId: String, datas: [Data], text: String?, replyToMessageId: String?, threadRootId: String?, context: ModelContext) async {
        let myUserIdStr = SupabaseManager.shared.currentUserId ?? ""
        
        var localMsgs: [MessageDB] = []
        var uploadJobs: [(String, Data, Data, String, String, Double?, Double?, String?, String?)] = []
        
        for (index, rawData) in datas.enumerated() {
            let localMsgId = UUID().uuidString.lowercased()
            
            // Порог: если файл ≤ 512 КБ — отправляем без сжатия (скриншоты, стикеры, мемы)
            let skipCompressionThreshold = 512 * 1024  // 512 KB
            let resizedData: Data
            if rawData.count <= skipCompressionThreshold {
                resizedData = rawData
            } else {
                // Resize до 2560px + HEIC компрессия для крупных фото
                resizedData = await ImageCompressor.shared.resizeIfNeeded(data: rawData)
            }
            
            // Определяем расширение по данным
            let fileExtension: String
            if resizedData.isHEIC {
                fileExtension = "heic"
            } else if resizedData.isPNG {
                fileExtension = "png"
            } else {
                fileExtension = "jpg"
            }
            let fileName = "\(localMsgId).\(fileExtension)"
            let thumbFileName = "\(localMsgId)_thumb.jpg"
            
            // Размеры после resize
            let dimensions = getImageDimensions(data: resizedData)
            let width = dimensions?.0
            let height = dimensions?.1
            let caption = (index == 0) ? text : nil
            
            print("СЕРВЕР/ОТПРАВКА: Размеры: w = \(String(describing: width)), h = \(String(describing: height)), формат: \(fileExtension), размер: \(resizedData.count / 1024)KB, сжатие: \(rawData.count > skipCompressionThreshold ? "да" : "нет")")
            
            // Для маленьких файлов thumbnail = оригинал (чёткое отображение в пузыре)
            let thumbData: Data
            if rawData.count <= skipCompressionThreshold {
                thumbData = resizedData  // Оригинал и так маленький
            } else {
                thumbData = await ImageCompressor.shared.generateThumbnailData(from: resizedData) ?? resizedData
            }
            
            // Генерируем BlurHash из thumbnail (CGImage для Swift 6 concurrency)
            let thumbDataForHash = thumbData
            let blurHash: String? = await Task.detached(priority: .utility) {
                guard let img = UIImage(data: thumbDataForHash),
                      let cg = img.cgImage else { return nil }
                return BlurHash.encode(cg, numberOfComponents: (4, 3))
            }.value
            
            // Сохраняем в dual-layer кэш
            await LocalCache.shared.saveImageData(resizedData, forKey: fileName)
            await LocalCache.shared.saveImageData(thumbData, forKey: thumbFileName)
            
            let localFileURL = LocalCache.shared.getPath(forKey: fileName)
            let localThumbURL = LocalCache.shared.getPath(forKey: thumbFileName)
            
            let content = MessageContent.image(imageURL: localFileURL, thumbURL: localThumbURL, text: caption, width: width, height: height, blurHash: blurHash)
            let localMsg = MessageDB(id: localMsgId, chatId: chatId, senderId: myUserIdStr, replyToMessageId: replyToMessageId, threadRootId: threadRootId, content: content, createdAt: Date(), status: .sending)
            
            localMsgs.append(localMsg)
            uploadJobs.append((localMsgId, resizedData, thumbData, fileName, thumbFileName, width, height, caption, blurHash))
        }
        
        for msg in localMsgs {
            context.insert(msg)
        }
        
        if let lastId = localMsgs.last?.id {
            let chatDesc = FetchDescriptor<ChatDB>(predicate: #Predicate { $0.id == chatId })
            if let chatDB = try? context.fetch(chatDesc).first {
                chatDB.lastMessageId = lastId
            }
        }
        
        try? context.save()
        
        // Уведомляем UI: превью изображений видны мгновенно
        NotificationCenter.default.post(name: .messageStatusChanged, object: chatId)
        
        for job in uploadJobs {
            let (msgIdStr, originalData, thumbData, originalFileName, thumbFileName, width, height, caption, blurHash) = job
            
            Task {
                let bgTask = UIApplication.shared.beginBackgroundTask { }
                let progressManager = UploadProgressManager.shared
                progressManager.setProgress(0.05, for: msgIdStr)
                
                do {
                    progressManager.setProgress(0.1, for: msgIdStr)
                    
                    async let originalURLTask = self.uploadImage(data: originalData, fileName: originalFileName)
                    async let thumbURLTask = self.uploadImage(data: thumbData, fileName: thumbFileName)
                    
                    progressManager.setProgress(0.3, for: msgIdStr)
                    
                    let (remoteOriginalURL, remoteThumbURL) = try await (originalURLTask, thumbURLTask)
                    
                    progressManager.setProgress(0.7, for: msgIdStr)
                    
                    // Сохраняем под remote-ключом в dual-layer кэш
                    await LocalCache.shared.saveImageData(originalData, forKey: remoteOriginalURL.lastPathComponent)
                    await LocalCache.shared.saveImageData(thumbData, forKey: remoteThumbURL.lastPathComponent)
                    
                    // Удаляем старые локальные файлы (дубликаты)
                    if originalFileName != remoteOriginalURL.lastPathComponent {
                        await LocalCache.shared.delete(forKey: originalFileName)
                    }
                    if thumbFileName != remoteThumbURL.lastPathComponent {
                        await LocalCache.shared.delete(forKey: thumbFileName)
                    }
                    
                    guard let msgUUID = UUID(uuidString: msgIdStr),
                          let chatUUID = UUID(uuidString: chatId) else {
                        print("MEDIA: Invalid UUID — msgId: \(msgIdStr), chatId: \(chatId)")
                        return
                    }
                    
                    let sendDTO = MessageInsertDTO(
                        id: msgUUID,
                        chat_id: chatUUID,
                        sender_id: UUID(uuidString: myUserIdStr)!,
                        reply_to_message_id: replyToMessageId != nil ? UUID(uuidString: replyToMessageId!) : nil,
                        thread_root_id: threadRootId != nil ? UUID(uuidString: threadRootId!) : nil,
                        content_type: "image",
                        content_text: caption,
                        content_image_url: remoteOriginalURL.absoluteString,
                        content_thumb_url: remoteThumbURL.absoluteString,
                        content_blur_hash: blurHash,
                        image_width: width,
                        image_height: height,
                        status: "sent"
                    )
                    
                    progressManager.setProgress(0.85, for: msgIdStr)
                    
                    // Fix 3: Сохраняем remote URL в MessageDB ДО INSERT.
                    // Если INSERT упадёт (обрыв сети), retry увидит https:// и пропустит повторный upload.
                    let fetchDesc = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == msgIdStr })
                    if let dbObj = try? context.fetch(fetchDesc).first {
                        dbObj.content = .image(imageURL: remoteOriginalURL, thumbURL: remoteThumbURL, text: caption, width: width, height: height, blurHash: blurHash)
                        try? context.save()
                    }
                    
                    try await self.client.from("messages")
                        .upsert(sendDTO, onConflict: "id", ignoreDuplicates: true)
                        .execute()
                    
                    if let dbObj = try? context.fetch(fetchDesc).first {
                        dbObj.status = .sent
                        try? context.save()
                    }
                    
                    progressManager.setProgress(1.0, for: msgIdStr)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    progressManager.removeProgress(for: msgIdStr)
                    
                    // Уведомить UI об изменении статуса
                    NotificationCenter.default.post(name: .messageStatusChanged, object: chatId)
                    
                } catch {
                    progressManager.removeProgress(for: msgIdStr)
                    
                    let fetchDesc = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == msgIdStr })
                    if let dbObj = try? context.fetch(fetchDesc).first {
                        dbObj.status = .failed
                        try? context.save()
                    }
                    
                    // Уведомить UI об ошибке
                    NotificationCenter.default.post(name: .messageStatusChanged, object: chatId)
                }
                
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }
    }
    
    func fetchMessagesByIds(_ ids: [String], context: ModelContext) async throws {
        guard !ids.isEmpty else { return }
        
        // Преобразуем строковые ID в UUID для запроса
        let uuids = ids.compactMap { UUID(uuidString: $0) }
        guard !uuids.isEmpty else { return }
        
        let messagesDTO: [MessageDTO] = try await client
            .from("messages")
            .select()
            .in("id", values: uuids)
            .execute()
            .value
        
        for dto in messagesDTO {
            let msgId = dto.id.uuidString.lowercased()
            let fetchDescriptor = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == msgId })
            let existing = try? context.fetch(fetchDescriptor).first
            
            if existing == nil {
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
                let msgDB = MessageDB(
                    id: msgId,
                    chatId: dto.chat_id.uuidString.lowercased(),
                    senderId: dto.sender_id.uuidString.lowercased(),
                    replyToMessageId: dto.reply_to_message_id?.uuidString.lowercased(),
                    threadRootId: dto.thread_root_id?.uuidString.lowercased(),
                    content: content,
                    createdAt: dto.created_at,
                    status: status
                )
                context.insert(msgDB)
            }
        }
        
        try? context.save()
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
    
    func fetchRegisteredContacts(phoneNumbers: [String]) async throws -> [User] {
        let usersDTO: [UserDTO] = try await client
            .rpc("get_registered_contacts", params: ["phone_numbers": phoneNumbers])
            .execute()
            .value
        
        return usersDTO.map {
            uDTO in
            User(
                id: uDTO.id.uuidString.lowercased(),
                phoneNumber: uDTO.phone_number ?? "",
                name: uDTO.name,
                nickname: uDTO.nickname ?? "",
                avatar: uDTO.avatar_url != nil ? URL(string: uDTO.avatar_url!) : nil,
                isOnline: uDTO.is_online
            )
        }
    }
    
    func createOrGetPersonalChat(with targetUserId: String, context: ModelContext) async throws -> Chat {
        guard let targetUserUUID = UUID(uuidString: targetUserId) else {
            throw URLError(.badURL)
        }
        
        let chatId: UUID = try await client
            .rpc("get_or_create_personal_chat", params:["p_target_user_id": targetUserUUID])
            .execute()
            .value
        
        _ = try await self.fetchChats(context: context)
        
        let localChats = try self.fetchLocalChats(context: context)
        if let newChat = localChats.first(where: { $0.id == chatId.uuidString.lowercased() }) {
            return newChat
        }
        
        throw NSError(domain: "ChatService", code: 404, userInfo:[NSLocalizedDescriptionKey: "Не удалось загрузить созданный чат"])
    }
    
    // MARK: - Group Chat Methods
    
    @MainActor
    func createGroupChat(name: String, avatarURL: URL?, participantIds: [String], context: ModelContext) async throws -> Chat {
        let uuids = participantIds.compactMap { UUID(uuidString: $0) }
        
        let chatId: UUID = try await client
            .rpc("create_group_chat", params: [
                "p_name": AnyJSON.string(name),
                "p_avatar_url": avatarURL != nil ? AnyJSON.string(avatarURL!.absoluteString) : AnyJSON.null,
                "p_participant_ids": AnyJSON.array(uuids.map { AnyJSON.string($0.uuidString.lowercased()) })
            ])
            .execute()
            .value
        
        // Перезагружаем все чаты, чтобы получить полную модель
        _ = try await self.fetchChats(context: context)
        
        let localChats = try self.fetchLocalChats(context: context)
        if let newChat = localChats.first(where: { $0.id == chatId.uuidString.lowercased() }) {
            return newChat
        }
        
        throw NSError(domain: "ChatService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Не удалось загрузить созданный групповой чат"])
    }
    
    @MainActor
    func updateGroupAvatar(chatId: String, avatarData: Data, context: ModelContext) async throws -> URL {
        guard let chatUUID = UUID(uuidString: chatId) else {
            throw NSError(domain: "ChatService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Некорректный UUID чата"])
        }
        
        // Вычисляем старый аватар для его удаления из облака
        var oldFileName: String? = nil
        let localChats = try? self.fetchLocalChats(context: context)
        if let chat = localChats?.first(where: { $0.id == chatId }),
           case .group(_, let url) = chat.type,
           let oldUrlString = url?.absoluteString,
           let name = oldUrlString.components(separatedBy: "/avatars/").last {
            oldFileName = name
        }
        
        // 1. Загрузка нового файла
        let newFileName = "group_\(chatId)_\(UUID().uuidString.lowercased()).jpg"
        try await client.storage
            .from("avatars")
            .upload(newFileName, data: avatarData, options: FileOptions(contentType: "image/jpeg"))
            
        let newAvatarURL = try client.storage.from("avatars").getPublicURL(path: newFileName).absoluteString
        
        // 2. Обновление базы
        try await client.from("chats")
            .update(["avatar_url": AnyJSON.string(newAvatarURL)])
            .eq("id", value: chatUUID.uuidString.lowercased())
            .execute()
            
        // 3. Удаление старого аватара (best effort)
        if let fileToRemove = oldFileName {
            _ = try? await client.storage.from("avatars").remove(paths: [fileToRemove])
        }
        
        // Перезагружаем чаты для обновления локальной базы
        _ = try await self.fetchChats(context: context)
        
        return URL(string: newAvatarURL)!
    }
    
    @MainActor
    func addGroupParticipant(chatId: String, userId: String) async throws {
        guard let chatUUID = UUID(uuidString: chatId),
              let userUUID = UUID(uuidString: userId) else {
            throw NSError(domain: "ChatService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Некорректный UUID"])
        }
        
        try await client
            .rpc("add_group_participant", params: [
                "p_chat_id": chatUUID.uuidString.lowercased(),
                "p_user_id": userUUID.uuidString.lowercased()
            ])
            .execute()
    }
    
    @MainActor
    func removeGroupParticipant(chatId: String, userId: String) async throws {
        guard let chatUUID = UUID(uuidString: chatId),
              let userUUID = UUID(uuidString: userId) else {
            throw NSError(domain: "ChatService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Некорректный UUID"])
        }
        
        try await client
            .rpc("remove_group_participant", params: [
                "p_chat_id": chatUUID.uuidString.lowercased(),
                "p_user_id": userUUID.uuidString.lowercased()
            ])
            .execute()
    }
    
    @MainActor
    func fetchGroupParticipants(chatId: String) async throws -> [(user: User, role: String)] {
        guard let chatUUID = UUID(uuidString: chatId) else {
            throw NSError(domain: "ChatService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Некорректный UUID"])
        }
        
        let participants: [ChatParticipantDTO] = try await client
            .from("chat_participants")
            .select()
            .eq("chat_id", value: chatUUID)
            .execute()
            .value
        
        let userIds = participants.map { $0.user_id }
        let usersDTO: [UserDTO] = try await client
            .from("users")
            .select()
            .in("id", values: userIds)
            .execute()
            .value
        
        return participants.compactMap { p in
            guard let uDTO = usersDTO.first(where: { $0.id == p.user_id }) else { return nil }
            let user = User(
                id: uDTO.id.uuidString.lowercased(),
                phoneNumber: uDTO.phone_number ?? "",
                name: uDTO.name,
                nickname: uDTO.nickname ?? "",
                avatar: uDTO.avatar_url != nil ? URL(string: uDTO.avatar_url!) : nil,
                isOnline: uDTO.is_online
            )
            return (user: user, role: p.role ?? "member")
        }
    }
    
    @MainActor
    func toggleMuteChat(chatId: String, isMuted: Bool, context: ModelContext) async throws {
        guard let chatUUID = UUID(uuidString: chatId),
              let myUserId = SupabaseManager.shared.currentUserId,
              let myUserUUID = UUID(uuidString: myUserId) else {
            return
        }
        
        try await client
            .from("chat_participants")
            .update(MuteParams(is_muted: isMuted))
            .eq("chat_id", value: chatUUID)
            .eq("user_id", value: myUserUUID)
            .execute()
        
        // Обновляем локально
        let descriptor = FetchDescriptor<ChatDB>(predicate: #Predicate { $0.id == chatId })
        if let chatDB = try context.fetch(descriptor).first {
            chatDB.isMuted = isMuted
            try context.save()
        }
    }
    
    @MainActor
    func isChatMuted(chatId: String) async throws -> Bool {
        guard let chatUUID = UUID(uuidString: chatId),
              let myUserId = SupabaseManager.shared.currentUserId,
              let myUserUUID = UUID(uuidString: myUserId) else {
            return false
        }
        
        let participants: [ChatParticipantDTO] = try await client
            .from("chat_participants")
            .select()
            .eq("chat_id", value: chatUUID)
            .eq("user_id", value: myUserUUID)
            .execute()
            .value
        
        return participants.first?.is_muted ?? false
    }
    
    // MARK: - Ephemeral Messaging
    
    /// Синхронизация пропущенных событий (удаления/редактирования) при запуске.
    /// Клиент запрашивает message_events с момента последней синхронизации.
    func syncMessageEvents(context: ModelContext) async throws {
        let lastSync = UserDefaults.standard.object(forKey: "lastEventSyncDate") as? Date ?? Date.distantPast
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sinceStr = formatter.string(from: lastSync)
        
        let events: [MessageEventDTO] = try await client
            .from("message_events")
            .select()
            .gt("created_at", value: sinceStr)
            .order("created_at", ascending: true)
            .execute()
            .value
        
        guard !events.isEmpty else {
            UserDefaults.standard.set(Date(), forKey: "lastEventSyncDate")
            return
        }
        
        print("SYNC: Получено \(events.count) пропущенных событий")
        
        for event in events {
            let msgId = event.message_id.uuidString.lowercased()
            let fetchDesc = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == msgId })
            guard let msgDB = try? context.fetch(fetchDesc).first else { continue }
            
            switch event.event_type {
            case "deleted":
                // Если событие от текущего пользователя — полное удаление,
                // иначе — локальное скрытие
                let actorId = event.actor_id.uuidString.lowercased()
                let myUserId = (SupabaseManager.shared.currentUserId ?? "").lowercased()
                
                if actorId == myUserId {
                    context.delete(msgDB)
                } else {
                    msgDB.isHiddenLocally = true
                }
                
            case "edited":
                if let newText = event.new_text {
                    msgDB.content = .text(newText)
                }
                
            default:
                break
            }
        }
        
        try? context.save()
        UserDefaults.standard.set(Date(), forKey: "lastEventSyncDate")
        print("SYNC: Применено \(events.count) событий")
    }
    
    /// Редактирование текстового сообщения (только своё, в пределах TTL)
    func editMessage(_ message: Message, newText: String, context: ModelContext) async throws {
        guard message.canEdit else {
            print("EDIT: Нельзя редактировать — TTL истёк или не текстовое")
            return
        }
        guard let msgUUID = UUID(uuidString: message.id),
              let chatUUID = UUID(uuidString: message.chatId),
              let myUserUUID = UUID(uuidString: SupabaseManager.shared.currentUserId ?? "") else {
            return
        }
        
        // 1. Обновляем на сервере
        try await client
            .from("messages")
            .update(MessageUpdateContentDTO(content_text: newText))
            .eq("id", value: msgUUID)
            .execute()
        
        // 2. Создаём event для синхронизации
        try await client
            .from("message_events")
            .insert(MessageEventInsertDTO(
                chat_id: chatUUID,
                message_id: msgUUID,
                event_type: "edited",
                new_text: newText,
                actor_id: myUserUUID
            ))
            .execute()
        
        // 3. Обновляем локально
        let msgId = message.id
        let fetchDesc = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == msgId })
        if let msgDB = try? context.fetch(fetchDesc).first {
            msgDB.content = .text(newText)
            try? context.save()
        }
        
        // 4. Обновляем snapshot в chats, если это последнее сообщение
        let chatId = message.chatId
        let chatDesc = FetchDescriptor<ChatDB>(predicate: #Predicate { $0.id == chatId })
        if let chatDB = try? context.fetch(chatDesc).first, chatDB.lastMessageId == message.id {
            chatDB.lastMessageText = newText
            try? context.save()
        }
        
        NotificationCenter.default.post(name: .messageStatusChanged, object: message.chatId)
        print("EDIT: Сообщение отредактировано: \(message.id)")
    }
    
    /// Удаление с TTL-логикой:
    /// - Своё ≤ TTL → удалить у всех (сервер + event)
    /// - Своё > TTL или чужое → скрыть только локально
    func deleteMessageEphemeral(_ message: Message, context: ModelContext) async throws {
        let msgId = message.id
        let chatId = message.chatId
        
        if message.canDeleteForEveryone {
            // === ГЛОБАЛЬНОЕ УДАЛЕНИЕ (своё, в пределах TTL) ===
            
            // 1. Удаляем с сервера
            try await client
                .from("messages")
                .delete()
                .eq("id", value: message.id)
                .execute()
            
            // 2. Создаём event (чтобы офлайн-клиенты узнали)
            // НО: если сообщение не доставлено (status=sent) — event НЕ создаём
            if message.status != .sending && message.status != .failed {
                if let chatUUID = UUID(uuidString: chatId),
                   let msgUUID = UUID(uuidString: msgId),
                   let myUserUUID = UUID(uuidString: SupabaseManager.shared.currentUserId ?? "") {
                    _ = try? await client
                        .from("message_events")
                        .insert(MessageEventInsertDTO(
                            chat_id: chatUUID,
                            message_id: msgUUID,
                            event_type: "deleted",
                            new_text: nil,
                            actor_id: myUserUUID
                        ))
                        .execute()
                }
            }
            
            // 3. Удаляем медиа из Storage (если есть)
            if case .image(let url, let thumbURL, _, _, _, _) = message.content {
                let fileName = url.lastPathComponent
                Task {
                    await LocalCache.shared.delete(forKey: fileName)
                }
                if let thumbName = thumbURL?.lastPathComponent {
                    Task {
                        await LocalCache.shared.delete(forKey: thumbName)
                    }
                }
                do {
                    _ = try await client.storage.from("chat_media").remove(paths: [fileName])
                } catch {
                    print("EPHEMERAL DELETE: Ошибка удаления медиа: \(error.localizedDescription)")
                }
            }
            
            let msgDesc = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == msgId })
            if let dbMessage = try? context.fetch(msgDesc).first {
                context.delete(dbMessage)
            }
            
            print("EPHEMERAL DELETE: Глобальное удаление — \(msgId)")
        } else {
            // === ЛОКАЛЬНОЕ СКРЫТИЕ (чужое или своё > TTL) ===
            
            let msgDesc = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == msgId })
            if let dbMessage = try? context.fetch(msgDesc).first {
                dbMessage.isHiddenLocally = true
            }
            
            print("EPHEMERAL DELETE: Локальное скрытие — \(msgId)")
        }
        
        // 5. Обновляем snapshot чата
        let chatDesc = FetchDescriptor<ChatDB>(predicate: #Predicate { $0.id == chatId })
        if let chatDB = try? context.fetch(chatDesc).first {
            chatDB.updateSnapshot(context: context)
        }
        
        try? context.save()
        
        NotificationCenter.default.post(name: .messageStatusChanged, object: chatId)
    }
    
    /// Batch-удаление с TTL-логикой
    func deleteMessagesEphemeral(_ messages: [Message], context: ModelContext) async throws {
        guard !messages.isEmpty else { return }
        
        // Разбиваем на группы
        let globalDeletes = messages.filter { $0.canDeleteForEveryone }
        let localHides = messages.filter { !$0.canDeleteForEveryone }
        
        // Глобальные удаления
        for msg in globalDeletes {
            try await deleteMessageEphemeral(msg, context: context)
        }
        
        // Локальные скрытия (batch)
        if !localHides.isEmpty {
            let hideIds = localHides.map { $0.id }
            let chatId = messages.first!.chatId
            let cId = chatId
            let msgDesc = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.chatId == cId })
            if let allMsgs = try? context.fetch(msgDesc) {
                for dbMsg in allMsgs where hideIds.contains(dbMsg.id) {
                    dbMsg.isHiddenLocally = true
                }
            }
            
            let chatDesc = FetchDescriptor<ChatDB>(predicate: #Predicate { $0.id == cId })
            if let chatDB = try? context.fetch(chatDesc).first {
                chatDB.updateSnapshot(context: context)
            }
            
            try? context.save()
            NotificationCenter.default.post(name: .messageStatusChanged, object: chatId)
        }
        
        print("EPHEMERAL BATCH: \(globalDeletes.count) удалено у всех, \(localHides.count) скрыто локально")
    }
    
    // MARK: - TODO: Backup
    
    /// TODO: Реализовать экспорт/импорт SwiftData через iCloud или локальный файл.
    /// Планируется:
    /// - Экспорт всех MessageDB + ChatDB в зашифрованный архив
    /// - Импорт на новом устройстве через AirDrop / iCloud Drive
    /// - Опциональная автоматическая синхронизация через iCloud (CloudKit)
    func exportChatBackup() async throws {
        throw NSError(domain: "ChatService", code: 501, userInfo: [NSLocalizedDescriptionKey: "Резервное копирование чатов пока не реализовано"])
    }
    
    func importChatBackup(from url: URL) async throws {
        throw NSError(domain: "ChatService", code: 501, userInfo: [NSLocalizedDescriptionKey: "Восстановление чатов из резервной копии пока не реализовано"])
    }
}

struct UpdateUnreadDTO: Encodable {
    let unread_count: Int
}

func getImageDimensions(data: Data) -> (Double, Double)? {
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Double,
          let height = properties[kCGImagePropertyPixelHeight] as? Double else {
        return nil
    }
    return (width, height)
}


