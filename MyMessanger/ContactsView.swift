//
//  ContactsView.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 18.03.2026.
//


import SwiftUI
import SwiftData

struct ContactsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    
    @State private var viewModel = ContactsViewModel()
    @State private var moderationNotice: String?
    @State private var pendingBlockUser: User?

    
    var onChatSelected: (Chat) -> Void
    
    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    ProgressView("Синхронизация контактов...")
                } else if let error = viewModel.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.exlamationmark")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        Text(error)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.gray)
                            .padding()
                        
                        Button("Настройки") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } else if viewModel.registeredUsers.isEmpty {
                    Text("Никто из ваших контактов еще не зарегистрирован в Тайге")
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    List(viewModel.registeredUsers) { user in
                        Button {
                            handleUserSelection(userId: user.id)
                        } label: {
                            HStack(spacing: 14) {
                                Circle()
                                    .fill(Color.blue.opacity(0.2))
                                    .frame(width: 44, height: 44)
                                    .overlay(Text(String(user.name.prefix(1)))
                                        .font(.headline)
                                        .foregroundColor(.blue)
                                    )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(user.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    
                                    Text(user.phoneNumber)
                                        .font(.subheadline)
                                        .foregroundColor(.gray)
                                }
                                
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                Task {
                                    let ok = await viewModel.reportUser(user)
                                    moderationNotice = ok ? "Жалоба отправлена. Спасибо." : "Не удалось отправить жалобу."
                                }
                            } label: {
                                Label("Пожаловаться", systemImage: "exclamationmark.bubble")
                            }
                            Button(role: .destructive) {
                                pendingBlockUser = user
                            } label: {
                                Label("Заблокировать", systemImage: "hand.raised")
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Новый чат")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Отмена") {
                        dismiss()
                    }
                }
            }

            .task {
                await viewModel.fetchContacts()
            }
            .alert("Готово", isPresented: Binding(
                get: { moderationNotice != nil },
                set: { if !$0 { moderationNotice = nil } }
            )) {
                Button("OK") { moderationNotice = nil }
            } message: {
                Text(moderationNotice ?? "")
            }
            .confirmationDialog(
                pendingBlockUser.map { "Заблокировать \($0.name)?" } ?? "Заблокировать?",
                isPresented: Binding(
                    get: { pendingBlockUser != nil },
                    set: { if !$0 { pendingBlockUser = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Заблокировать", role: .destructive) {
                    if let user = pendingBlockUser {
                        Task {
                            let ok = await viewModel.blockUser(user)
                            moderationNotice = ok ? "Пользователь заблокирован." : "Не удалось заблокировать."
                        }
                    }
                }
                Button("Отмена", role: .cancel) { }
            } message: {
                Text("Вы больше не будете видеть сообщения этого пользователя.")
            }
        }
    }
    
    private func handleUserSelection(userId: String) {
        let currentUserId = SupabaseManager.shared.currentUserId ?? ""
        
        // Проверяем — может чат с этим пользователем уже существует локально
        if let existingChat = findExistingPersonalChat(with: userId, context: context) {
            onChatSelected(existingChat)
            return
        }
        
        // Создаём draft-Chat (без обращения к серверу)
        let targetUser = viewModel.registeredUsers.first(where: { $0.id == userId })
        let currentUser = User(
            id: currentUserId,
            phoneNumber: "",
            name: "",  // не отображается — displayTitle берёт собеседника
            nickname: ""
        )
        
        let draftChat = Chat(
            id: "draft_\(userId)",
            type: .personal,
            participants: [targetUser, currentUser].compactMap { $0 },
            lastMessage: nil,
            unreadCount: 0
        )
        
        onChatSelected(draftChat)
    }
    
    /// Поиск существующего личного чата с пользователем в SwiftData
    private func findExistingPersonalChat(with userId: String, context: ModelContext) -> Chat? {
        let descriptor = FetchDescriptor<ChatDB>()
        guard let allChats = try? context.fetch(descriptor) else { return nil }
        
        let currentUserId = SupabaseManager.shared.currentUserId ?? ""
        
        return allChats
            .filter { if case .personal = $0.type { return $0.participantIds.contains(userId) && $0.participantIds.contains(currentUserId) } else { return false } }
            .compactMap { chatDB -> Chat? in
                var participants = [User]()
                for uid in chatDB.participantIds {
                    let userDesc = FetchDescriptor<UserDB>(predicate: #Predicate { $0.id == uid })
                    if let userDB = try? context.fetch(userDesc).first {
                        participants.append(userDB.toDomain())
                    }
                }
                var lastMessage: Message? = nil
                if let lastMsgId = chatDB.lastMessageId {
                    let msgDesc = FetchDescriptor<MessageDB>(predicate: #Predicate { $0.id == lastMsgId })
                    if let msgDB = try? context.fetch(msgDesc).first {
                        lastMessage = msgDB.toDomain()
                    }
                }
                return chatDB.toDomain(participants: participants, lastMessage: lastMessage)
            }
            .first
    }
}
