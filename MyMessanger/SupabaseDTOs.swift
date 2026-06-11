//
//  SupabaseDTOs.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 11.03.2026.
//


import Foundation

struct UserDTO: Codable {
    let id: UUID
    let phone_number: String?
    let name: String
    let nickname: String?
    let avatar_url: String?
    let is_online: Bool
}

struct ChatDTO: Codable {
    let id: UUID
    let type: String
    let name: String?
    let avatar_url: String?
    let created_at: Date
    let last_message_id: UUID?
    // Snapshot последнего сообщения
    let last_message_text: String?
    let last_message_at: Date?
    let last_message_sender_id: UUID?
    let last_message_type: String?
}

struct ChatParticipantDTO: Codable {
    let chat_id: UUID
    let user_id: UUID
    let unread_count: Int
    let role: String?
    let is_muted: Bool?
}

// MARK: - Group Chat DTOs

struct CreateGroupChatParams: Encodable {
    let p_name: String
    let p_avatar_url: String?
    let p_participant_ids: [UUID]
}

struct GroupParticipantParams: Encodable {
    let p_chat_id: UUID
    let p_user_id: UUID
}

struct MuteParams: Encodable {
    let is_muted: Bool
}

struct MessageDTO: Codable {
    let id: UUID
    let chat_id: UUID
    let sender_id: UUID
    let reply_to_message_id: UUID?
    let thread_root_id: UUID?
    let content_type: String
    let content_text: String?
    let content_image_url: String?
    let content_thumb_url: String?
    let content_blur_hash: String?
    let image_width: Double?
    let image_height: Double?
    let status: String
    let created_at: Date
}

struct MessageInsertDTO: Encodable, Sendable {
    let id: UUID
    let chat_id: UUID
    let sender_id: UUID
    let reply_to_message_id: UUID?
    let thread_root_id: UUID?
    let content_type: String
    let content_text: String?
    let content_image_url: String?
    let content_thumb_url: String?
    let content_blur_hash: String?
    let image_width: Double?
    let image_height: Double?
    let status: String
    var created_at: Date? = nil
}

struct UpdateChatLastMessageDTO: Encodable {
    let last_message_id: UUID
}

struct RealtimeMessageDTO: Codable, Sendable {
    let id: UUID
    let chat_id: UUID
    let sender_id: UUID
    let reply_to_message_id: UUID?
    let thread_root_id: UUID?
    let content_type: String
    let content_text: String?
    let content_image_url: String?
    let content_thumb_url: String?
    let content_blur_hash: String?
    let image_width: Double?
    let image_height: Double?
    let status: String
    let created_at: String
}

// MARK: - Message Events (ephemeral messaging)

struct MessageEventDTO: Codable, Sendable {
    let id: UUID
    let chat_id: UUID
    let message_id: UUID
    let event_type: String  // "deleted" | "edited"
    let new_text: String?
    let actor_id: UUID
    let created_at: Date
}

struct MessageEventInsertDTO: Encodable {
    let chat_id: UUID
    let message_id: UUID
    let event_type: String
    let new_text: String?
    let actor_id: UUID
}

struct MessageUpdateContentDTO: Encodable {
    let content_text: String
}
