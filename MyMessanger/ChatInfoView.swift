//
//  ChatInfoView.swift
//  MyMessanger
//
//  Экран профиля личного (1:1) чата: аватар собеседника по центру + действия внизу
//  («Удалить чат», «Очистить чат», «Пожаловаться», «Заблокировать»). Открывается
//  тапом по аватарке/имени в шапке ChatDetailView (аналог GroupInfoView для групп).
//  Жалоба/блокировка переехали сюда из меню «…».
//

import SwiftUI
import SwiftData

@MainActor
struct ChatInfoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    let chat: Chat
    /// Собеседник в 1:1 (nil — self-chat/битые участники: жалоба/блок скрываются).
    let interlocutor: User?
    /// Вызывается после «Очистить чат», чтобы открытый чат сразу опустел (refreshWindow).
    var onChatCleared: () -> Void
    /// Вызывается после «Удалить чат»/«Заблокировать», чтобы закрыть и сам чат (pop).
    var onChatClosed: () -> Void

    private let chatService: ChatServiceProtocol = SupabaseChatService()

    @State private var showDeleteConfirm = false
    @State private var showClearConfirm = false
    @State private var showBlockConfirm = false
    @State private var moderationNotice: String?
    @State private var errorMessage: String?
    @State private var fullscreenAvatar: FullscreenImageItem?

    /// Крупный аватар для профиля/fullscreen — предпочитаем полноразмерную версию.
    private var profileAvatarURL: URL? { interlocutor?.avatarFull ?? interlocutor?.avatar }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()

                avatarView

                Text(chat.displayTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)

                if let nickname = interlocutor?.nickname, !nickname.isEmpty {
                    Text("@\(nickname)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(spacing: 12) {
                    actionRow("Удалить чат", systemImage: "trash", tint: .red) {
                        showDeleteConfirm = true
                    }
                    actionRow("Очистить чат", systemImage: "eraser", tint: .primary) {
                        showClearConfirm = true
                    }
                    if interlocutor != nil {
                        actionRow("Пожаловаться", systemImage: "exclamationmark.bubble", tint: .primary) {
                            if let user = interlocutor { performReport(user) }
                        }
                        actionRow("Заблокировать", systemImage: "hand.raised", tint: .red) {
                            showBlockConfirm = true
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
            .navigationTitle("Инфо")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .confirmationDialog("Очистить чат?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Очистить", role: .destructive) { performClear() }
                Button("Отмена", role: .cancel) { }
            } message: {
                Text("Сообщения будут скрыты на этом устройстве. У собеседника переписка сохранится.")
            }
            .confirmationDialog("Удалить чат?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Удалить безвозвратно", role: .destructive) { performDelete() }
                Button("Отмена", role: .cancel) { }
            } message: {
                Text("Чат, все его сообщения и медиа будут удалены с этого устройства без возможности восстановления.")
            }
            .confirmationDialog(
                interlocutor.map { "Заблокировать \($0.name)?" } ?? "Заблокировать?",
                isPresented: $showBlockConfirm,
                titleVisibility: .visible
            ) {
                Button("Заблокировать", role: .destructive) {
                    if let user = interlocutor { performBlock(user) }
                }
                Button("Отмена", role: .cancel) { }
            } message: {
                Text("Вы больше не будете видеть сообщения этого пользователя.")
            }
            .alert("Готово", isPresented: Binding(
                get: { moderationNotice != nil },
                set: { if !$0 { moderationNotice = nil } }
            )) {
                Button("ОК", role: .cancel) { }
            } message: {
                Text(moderationNotice ?? "")
            }
            .alert("Ошибка", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("ОК", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .overlay {
            if let item = fullscreenAvatar {
                FullscreenImageViewer(
                    imageURL: item.imageURL,
                    thumbURL: item.thumbURL,
                    blurHash: item.blurHash,
                    imageWidth: item.imageWidth,
                    imageHeight: item.imageHeight,
                    onDismiss: { withAnimation(.easeOut(duration: 0.25)) { fullscreenAvatar = nil } }
                )
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var avatarView: some View {
        if let avatar = profileAvatarURL {
            CachedImageView(avatarURL: avatar, size: 120)
                .clipShape(Circle())
                .onTapGesture {
                    // Тап по аватарке → fullscreen в максимальном качестве (полная версия).
                    fullscreenAvatar = FullscreenImageItem(
                        imageURL: avatar,
                        thumbURL: interlocutor?.avatar,
                        blurHash: nil,
                        imageWidth: nil,
                        imageHeight: nil
                    )
                }
        } else {
            Circle()
                .fill(Color.blue.opacity(0.2))
                .frame(width: 120, height: 120)
                .overlay(
                    Text(String(chat.displayTitle.prefix(1)))
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                )
        }
    }

    private func actionRow(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                Text(title)
                Spacer()
            }
            .font(.body)
            .foregroundStyle(tint)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Actions

    /// «Очистить чат» = та же логика, что в настройках хранилища (серверная метка + локальное скрытие).
    private func performClear() {
        Task {
            do {
                try await chatService.clearChat(chatId: chat.id, context: context)
                onChatCleared()   // открытый чат сразу опустеет
                dismiss()
            } catch {
                errorMessage = "Не удалось очистить чат. Попробуйте позже."
            }
        }
    }

    /// «Удалить чат» = полное локальное удаление (как из списка чатов).
    private func performDelete() {
        Task {
            do {
                try await chatService.deleteChat(chatId: chat.id, context: context)
                dismiss()        // закрываем лист профиля
                onChatClosed()   // закрываем и сам чат (pop из стека)
            } catch {
                errorMessage = "Не удалось удалить чат. Попробуйте позже."
            }
        }
    }

    private func performBlock(_ user: User) {
        Task {
            do {
                try await chatService.blockUser(user.id)
                // Обновляем список чатов, чтобы скрытый 1:1 с заблокированным исчез сразу.
                NotificationCenter.default.post(name: .newChatDetected, object: nil)
                dismiss()
                onChatClosed()
            } catch {
                errorMessage = "Не удалось заблокировать. Попробуйте позже."
            }
        }
    }

    private func performReport(_ user: User) {
        Task {
            do {
                try await chatService.reportUser(userId: user.id, reason: "Жалоба на пользователя")
                moderationNotice = "Жалоба отправлена. Спасибо."
            } catch {
                errorMessage = "Не удалось отправить жалобу. Попробуйте позже."
            }
        }
    }
}
