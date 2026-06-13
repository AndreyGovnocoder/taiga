//
//  ServiceProtocols.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 10.03.2026.
//


import Foundation
import SwiftData

protocol AuthServiceProtocol {
    func requestSMS(phoneNumber: String) async throws
    func verifyCode(code: String) async throws -> User
    
    func loginWithEmail(email: String, password: String) async throws -> User
    func registerWithEmail(email: String, password: String, name: String, nickname: String, phoneNumber: String) async throws -> User
    func checkUserExists(phoneNumber: String) async throws -> Bool
    func checkNicknameExists(nickname: String) async throws -> Bool
    
    func updateProfile(name: String, nickname: String, avatarData: Data?) async throws -> User
    func deleteAccount() async throws
    
    func logout() async throws
    var currentUser: User? { get }
}

protocol ChatServiceProtocol {
    @MainActor func fetchChats(context: ModelContext) async throws -> [Chat]
    @MainActor func fetchLocalChats(context: ModelContext) throws -> [Chat]
    @MainActor func fetchMessages(for chatId: String, limit: Int, before date: Date?, context: ModelContext) async throws -> Int
    @MainActor func sendMessage(chatId: String, content: MessageContent, replyToMessageId: String?, threadRootId: String?, context: ModelContext) async throws
    
    /// Фаза 1: мгновенная вставка сообщения в SwiftData (status: .sending).
    /// Возвращает ID созданного сообщения.
    @MainActor func insertLocalMessage(chatId: String, content: MessageContent, replyToMessageId: String?, threadRootId: String?, context: ModelContext) throws -> String
    
    /// Фаза 2: отправка сообщения на Supabase. Обновляет status: .sending → .sent.
    /// При ошибке сети оставляет status: .sending (для авторетрая).
    @MainActor func deliverMessage(messageId: String, context: ModelContext) async throws
    
    /// Повторная отправка всех сообщений со статусом .sending (авторетрай при восстановлении сети).
    @MainActor func retryPendingMessages(context: ModelContext) async
    
    @MainActor func reconnectRealtime() async
    @MainActor func subscribeToAllChats(container: ModelContainer) async throws
    @MainActor func markChatAsRead(chatId: String, context: ModelContext) async throws
    @MainActor func uploadImage(data: Data, fileName: String) async throws -> URL
    @MainActor func deleteMessage(_ message: Message, context: ModelContext) async throws
    @MainActor func deleteMessages(_ messages: [Message], context: ModelContext) async throws
    @MainActor func sendMediaMessages(chatId: String, datas: [Data], text: String?, replyToMessageId: String?, threadRootId: String?, context: ModelContext) async
    @MainActor func retryMessage(_ message: Message, context: ModelContext) async throws
    @MainActor func fetchMessagesByIds(_ ids: [String], context: ModelContext) async throws
    @MainActor func fetchRegisteredContacts(phoneNumbers: [String]) async throws -> [User]
    @MainActor func createOrGetPersonalChat(with targetUserId: String, context: ModelContext) async throws -> Chat

    // MARK: - Chat management (local)
    /// Полностью удаляет чат с УСТРОЙСТВА: все сообщения (MessageDB), сам ChatDB и файлы
    /// медиа этого чата из LocalCache. Сервер НЕ трогает (чат вернётся пустым, если
    /// собеседник пришлёт новое сообщение). Аватары и медиа других чатов не затрагиваются.
    @MainActor func deleteChat(chatId: String, context: ModelContext) async throws
    /// «Очистить чат»: серверная метка cleared_at (RPC, персистентно) + мгновенное локальное
    /// скрытие. Сообщения старше метки больше не тянутся/не показываются (переживает ресинк).
    /// На сервере сами сообщения сохраняются. Возвращает число локально скрытых.
    @MainActor @discardableResult func clearChat(chatId: String, context: ModelContext) async throws -> Int
    /// Точечная дозагрузка сообщения по id (фоновый пуш) в общий mainContext. true — если вставлено.
    @MainActor @discardableResult func fetchAndStoreMessage(messageId: String, container: ModelContainer) async throws -> Bool

    // MARK: - Group Chat
    @MainActor func createGroupChat(name: String, avatarURL: URL?, participantIds: [String], context: ModelContext) async throws -> Chat
    @MainActor func updateGroupAvatar(chatId: String, avatarData: Data, context: ModelContext) async throws -> URL
    @MainActor func addGroupParticipant(chatId: String, userId: String) async throws
    @MainActor func removeGroupParticipant(chatId: String, userId: String) async throws
    @MainActor func fetchGroupParticipants(chatId: String) async throws -> [(user: User, role: String)]
    @MainActor func toggleMuteChat(chatId: String, isMuted: Bool, context: ModelContext) async throws
    @MainActor func isChatMuted(chatId: String) async throws -> Bool
    
    // MARK: - Ephemeral Messaging
    @MainActor func syncMessageEvents(context: ModelContext) async throws
    @MainActor func editMessage(_ message: Message, newText: String, context: ModelContext) async throws
    @MainActor func deleteMessageEphemeral(_ message: Message, context: ModelContext) async throws
    @MainActor func deleteMessagesEphemeral(_ messages: [Message], context: ModelContext) async throws
    
    // MARK: - UGC Moderation
    @MainActor func blockUser(_ userId: String) async throws
    @MainActor func unblockUser(_ userId: String) async throws
    @MainActor func fetchBlockedUsers() async throws -> [User]
    @MainActor func reportContent(message: Message, reason: String) async throws
    @MainActor func reportUser(userId: String, reason: String) async throws

    // MARK: - Backup (TODO)
    func exportChatBackup() async throws
    func importChatBackup(from url: URL) async throws
}


