//
//  BlockedUsersView.swift
//  MyMessanger
//
//  Список заблокированных пользователей (UGC-модерация). Открывается из настроек аккаунта.
//  Загружает список через get_blocked_users, позволяет разблокировать.
//

import SwiftUI

struct BlockedUsersView: View {
    private let chatService: ChatServiceProtocol = SupabaseChatService()

    @State private var blockedUsers: [User] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Загрузка...")
            } else if blockedUsers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                    Text("Нет заблокированных пользователей")
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            } else {
                List {
                    ForEach(blockedUsers) { user in
                        HStack(spacing: 14) {
                            avatar(for: user)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name)
                                    .font(.body)
                                if !user.nickname.isEmpty {
                                    Text("@\(user.nickname)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button("Разблокировать") {
                                unblock(user)
                            }
                            .buttonStyle(.borderless)
                            .font(.callout)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Заблокированные")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
        }
        .alert("Ошибка", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func avatar(for user: User) -> some View {
        if let avatarURL = user.avatar {
            CachedImageView(avatarURL: avatarURL, size: 40)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.blue.opacity(0.2))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(user.name.prefix(1)))
                        .font(.headline)
                        .foregroundColor(.blue)
                )
        }
    }

    private func load() async {
        isLoading = true
        do {
            blockedUsers = try await chatService.fetchBlockedUsers()
        } catch {
            errorMessage = "Не удалось загрузить список: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func unblock(_ user: User) {
        Task {
            do {
                try await chatService.unblockUser(user.id)
                blockedUsers.removeAll { $0.id == user.id }
            } catch {
                errorMessage = "Не удалось разблокировать: \(error.localizedDescription)"
            }
        }
    }
}
