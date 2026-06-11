//
//  GroupInfoView.swift
//  MyMessanger
//
//  Created by Antigravity AI on 27.03.2026.
//

import SwiftUI
import SwiftData
import Contacts
import PhotosUI

/// Экран информации о групповом чате.
/// Показывает список участников, позволяет добавить/удалить участников (admin),
/// покинуть группу, и toggle mute.
struct GroupInfoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    
    let chat: Chat
    
    @State private var participants: [(user: User, role: String)] = []
    @State private var isLoading: Bool = true
    @State private var isMuted: Bool = false
    @State private var errorMessage: String?
    @State private var showAddParticipant: Bool = false
    @State private var showLeaveConfirm: Bool = false
    
    @State private var groupAvatar: URL? = nil
    @State private var avatarItem: PhotosPickerItem?
    @State private var isUpdatingAvatar: Bool = false
    
    private var initialAvatarURL: URL? {
        if case .group(_, let url) = chat.type {
            return url
        }
        return nil
    }
    
    private let chatService: ChatServiceProtocol = SupabaseChatService()
    
    private var currentUserId: String {
        SupabaseManager.shared.currentUserId ?? ""
    }
    
    var body: some View {
        NavigationStack {
            List {
                // MARK: - Заголовок группы
                Section {
                    HStack(spacing: 16) {
                        // Аватар-заглушка или фото
                        ZStack(alignment: .bottomTrailing) {
                            if let url = groupAvatar {
                                CachedImageView(avatarURL: url, size: 64)
                                    .clipShape(Circle())
                            } else {
                                ZStack {
                                    Circle()
                                        .fill(Color.blue.opacity(0.15))
                                        .frame(width: 64, height: 64)
                                    
                                    Image(systemName: "person.3.fill")
                                        .font(.title2)
                                        .foregroundStyle(.blue.opacity(0.6))
                                }
                            }
                            
                            if chat.isAdmin {
                                PhotosPicker(selection: $avatarItem, matching: .images) {
                                    Circle()
                                        .fill(Color.blue)
                                        .frame(width: 24, height: 24)
                                        .overlay(
                                            Image(systemName: "camera.fill")
                                                .font(.system(size: 12))
                                                .foregroundColor(.white)
                                        )
                                }
                                .buttonStyle(.plain)
                                .offset(x: 4, y: 4)
                                .disabled(isUpdatingAvatar)
                            }
                            
                            if isUpdatingAvatar {
                                Circle()
                                    .fill(Color.black.opacity(0.4))
                                    .frame(width: 64, height: 64)
                                ProgressView()
                                    .tint(.white)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chat.displayTitle)
                                .font(.title2)
                                .fontWeight(.semibold)
                            
                            Text("\(participants.count) участников")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // MARK: - Уведомления
                Section {
                    Toggle(isOn: $isMuted) {
                        Label("Без звука", systemImage: isMuted ? "bell.slash.fill" : "bell.fill")
                    }
                    .onChange(of: isMuted) { _, newValue in
                        Task {
                            try? await chatService.toggleMuteChat(chatId: chat.id, isMuted: newValue, context: context)
                        }
                    }
                }
                
                // MARK: - Участники
                Section {
                    if chat.isAdmin {
                        Button {
                            showAddParticipant = true
                        } label: {
                            Label("Добавить участника", systemImage: "person.badge.plus")
                                .foregroundStyle(.blue)
                        }
                    }
                    
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else {
                        ForEach(participants, id: \.user.id) { participant in
                            HStack(spacing: 14) {
                                if let avatarURL = participant.user.avatar {
                                    CachedImageView(avatarURL: avatarURL, size: 40)
                                        .clipShape(Circle())
                                } else {
                                    Circle()
                                        .fill(Color.blue.opacity(0.2))
                                        .frame(width: 40, height: 40)
                                        .overlay(
                                            Text(String(participant.user.name.prefix(1)))
                                                .font(.headline)
                                                .foregroundColor(.blue)
                                        )
                                }
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(participant.user.name)
                                            .font(.body)
                                        
                                        if participant.role == "admin" {
                                            Text("admin")
                                                .font(.caption2)
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.orange.cornerRadius(4))
                                        }
                                    }
                                    
                                    if !participant.user.nickname.isEmpty {
                                        Text("@\(participant.user.nickname)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                
                                Spacer()
                                
                                if participant.user.id == currentUserId {
                                    Text("Вы")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if chat.isAdmin && participant.user.id != currentUserId {
                                    Button(role: .destructive) {
                                        removeParticipant(participant.user)
                                    } label: {
                                        Label("Удалить", systemImage: "person.badge.minus")
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Участники (\(participants.count))")
                }
                
                // MARK: - Покинуть группу
                Section {
                    Button(role: .destructive) {
                        showLeaveConfirm = true
                    } label: {
                        Label("Покинуть группу", systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Инфо")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        dismiss()
                    }
                }
            }
            .alert("Ошибка", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .confirmationDialog("Покинуть группу?", isPresented: $showLeaveConfirm, titleVisibility: .visible) {
                Button("Покинуть", role: .destructive) {
                    leaveGroup()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Вы не сможете отправлять и получать сообщения в этой группе.")
            }
            .sheet(isPresented: $showAddParticipant) {
                AddParticipantView(
                    chatId: chat.id,
                    existingParticipantIds: Set(participants.map { $0.user.id }),
                    chatService: chatService,
                    onAdded: {
                        Task { await loadParticipants() }
                    }
                )
            }
            .task {
                groupAvatar = initialAvatarURL
                isMuted = chat.isMuted
                await loadParticipants()
            }
            .onChange(of: avatarItem) { _, newItem in
                guard let item = newItem else { return }
                Task {
                    isUpdatingAvatar = true
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        if let compressed = await ImageCompressor.shared.generateThumbnailData(from: data, maxPixelSize: 600) {
                            do {
                                let newURL = try await chatService.updateGroupAvatar(chatId: chat.id, avatarData: compressed, context: context)
                                self.groupAvatar = newURL
                            } catch {
                                self.errorMessage = "Ошибка обновления аватара: \(error.localizedDescription)"
                            }
                        }
                    }
                    isUpdatingAvatar = false
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func loadParticipants() async {
        isLoading = true
        do {
            participants = try await chatService.fetchGroupParticipants(chatId: chat.id)
            // Сортировка: admin сверху, затем по имени
            participants.sort { lhs, rhs in
                if lhs.role == "admin" && rhs.role != "admin" { return true }
                if lhs.role != "admin" && rhs.role == "admin" { return false }
                return lhs.user.name < rhs.user.name
            }
        } catch {
            errorMessage = "Не удалось загрузить участников: \(error.localizedDescription)"
        }
        isLoading = false
    }
    
    private func removeParticipant(_ user: User) {
        Task {
            do {
                try await chatService.removeGroupParticipant(chatId: chat.id, userId: user.id)
                participants.removeAll { $0.user.id == user.id }
            } catch {
                errorMessage = "Ошибка удаления: \(error.localizedDescription)"
            }
        }
    }
    
    private func leaveGroup() {
        Task {
            do {
                try await chatService.removeGroupParticipant(chatId: chat.id, userId: currentUserId)
                // TODO: Удалить чат из локального кэша и закрыть экран
                dismiss()
            } catch {
                errorMessage = "Ошибка выхода из группы: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - AddParticipantView

/// Мини-экран для добавления нового участника в группу.
struct AddParticipantView: View {
    @Environment(\.dismiss) private var dismiss
    
    let chatId: String
    let existingParticipantIds: Set<String>
    let chatService: ChatServiceProtocol
    var onAdded: () -> Void
    
    @State private var contacts: [User] = []
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Загрузка контактов...")
                } else if contacts.isEmpty {
                    ContentUnavailableView("Нет доступных контактов", systemImage: "person.crop.circle.badge.xmark")
                } else {
                    List(contacts) { user in
                        Button {
                            addParticipant(user)
                        } label: {
                            HStack(spacing: 14) {
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
                                
                                VStack(alignment: .leading) {
                                    Text(user.name)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(user.phoneNumber)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Добавить участника")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                }
            }
            .alert("Ошибка", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                await loadAvailableContacts()
            }
        }
    }
    
    private func loadAvailableContacts() async {
        isLoading = true
        do {
            let store = CNContactStore()
            let granted = try await store.requestAccess(for: .contacts)
            guard granted else {
                isLoading = false
                return
            }
            
            let rawPhoneNumbers = try await Task.detached(priority: .userInitiated) {
                let keys = [
                    CNContactPhoneNumbersKey as CNKeyDescriptor
                ]
                let request = CNContactFetchRequest(keysToFetch: keys)
                var numbers = Set<String>()
                try store.enumerateContacts(with: request) { contact, _ in
                    for phoneVal in contact.phoneNumbers {
                        let raw = phoneVal.value.stringValue.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                        if !raw.isEmpty {
                            numbers.insert("+" + raw)
                        }
                    }
                }
                return Array(numbers)
            }.value
            
            let allUsers = try await chatService.fetchRegisteredContacts(phoneNumbers: rawPhoneNumbers)
            let currentUserId = SupabaseManager.shared.currentUserId ?? ""
            
            contacts = allUsers.filter {
                $0.id != currentUserId && !existingParticipantIds.contains($0.id)
            }.sorted { $0.name < $1.name }
            
        } catch {
            errorMessage = "Ошибка: \(error.localizedDescription)"
        }
        isLoading = false
    }
    
    private func addParticipant(_ user: User) {
        Task {
            do {
                try await chatService.addGroupParticipant(chatId: chatId, userId: user.id)
                contacts.removeAll { $0.id == user.id }
                onAdded()
                if contacts.isEmpty {
                    dismiss()
                }
            } catch {
                errorMessage = "Ошибка добавления: \(error.localizedDescription)"
            }
        }
    }
}
