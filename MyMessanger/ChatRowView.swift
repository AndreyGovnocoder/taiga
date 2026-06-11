//
//  ChatRowView.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 09.03.2026.
//

import SwiftUI

struct ChatRowView: View {
    let chat: Chat
    
    private var chatAvatarURL: URL? {
        if case .group(_, let url) = chat.type {
            return url
        }
        let currentUserId = SupabaseManager.shared.currentUserId ?? ""
        return chat.participants.first(where: { $0.id != currentUserId })?.avatar
    }
    
    var body: some View {
        HStack {
            // Аватар
            if let avatarURL = chatAvatarURL {
                CachedImageView(avatarURL: avatarURL, size: 50)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: 50, height: 50)
                    .overlay(
                        Group {
                            if chat.isGroup {
                                Image(systemName: "person.3.fill")
                                    .font(.body)
                                    .foregroundColor(.blue)
                            } else {
                                Text(String(chat.displayTitle.prefix(1)))
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.blue)
                            }
                        }
                    )
            }
            
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(chat.displayTitle)
                        .font(.headline)
                    
                    if chat.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Text(chat.previewText ?? "Нет сообщений")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 5) {
                if let date = chat.lastActivityDate {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
                if chat.unreadCount > 0 {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Text("\(chat.unreadCount)")
                                .font(.caption2)
                                .foregroundColor(Color.white)
                                .fontWeight(.bold)
                            
                        )
                }
            }
        }
        .padding()
        .contentShape(Rectangle())
    }
}

