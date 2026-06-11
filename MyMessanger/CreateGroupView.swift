//
//  CreateGroupView.swift
//  MyMessanger
//
//  Created by Antigravity AI on 27.03.2026.
//

import SwiftUI
import SwiftData
import Contacts

// MARK: - CreateGroupView

/// Экран создания группового чата.
/// Содержит: название группы, мульти-выбор участников из контактов, кнопку «Создать».
struct CreateGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    
    var onGroupCreated: (Chat) -> Void
    
    @State private var groupName: String = ""
    @State private var selectedUserIds: Set<String> = []
    @State private var registeredUsers: [User] = []
    @State private var isLoadingContacts: Bool = true
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?
    @State private var contactsError: String?
    
    private let chatService: ChatServiceProtocol = SupabaseChatService()
    
    private var canCreate: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && selectedUserIds.count >= 1
        && !isCreating
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Заголовок группы
                groupNameSection
                
                Divider()
                
                // Выбранные участники (горизонтальная полоска)
                if !selectedUserIds.isEmpty {
                    selectedUsersStrip
                    Divider()
                }
                
                // Список контактов
                contactsListSection
            }
            .navigationTitle("Новая группа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Создать") {
                        createGroup()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canCreate)
                }
            }
            .overlay {
                if isCreating {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        ProgressView("Создание группы...")
                            .padding()
                            .background(Color(UIColor.systemBackground))
                            .cornerRadius(12)
                            .shadow(radius: 10)
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
            .task {
                await loadContacts()
            }
        }
    }
    
    // MARK: - Group Name
    
    private var groupNameSection: some View {
        HStack(spacing: 12) {
            // Заглушка аватара
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 56, height: 56)
                
                Image(systemName: "camera.fill")
                    .font(.title3)
                    .foregroundStyle(.blue.opacity(0.5))
            }
            
            TextField("Название группы", text: $groupName)
                .font(.title3)
                .textInputAutocapitalization(.sentences)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    
    // MARK: - Selected Users Strip
    
    private var selectedUsersStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(selectedUsers, id: \.id) { user in
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Circle()
                                .fill(Color.blue.opacity(0.2))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Text(String(user.name.prefix(1)))
                                        .font(.headline)
                                        .foregroundColor(.blue)
                                )
                            
                            Button {
                                withAnimation(Animation.easeInOut(duration: 0.2)) {
                                    _ = selectedUserIds.remove(user.id)
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.gray)
                                    .background(Circle().fill(Color(UIColor.systemBackground)).frame(width: 14, height: 14))
                            }
                            .offset(x: 4, y: -4)
                        }
                        
                        Text(user.name.components(separatedBy: " ").first ?? user.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 56)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
    
    // MARK: - Contacts List
    
    @ViewBuilder
    private var contactsListSection: some View {
        if isLoadingContacts {
            Spacer()
            ProgressView("Загрузка контактов...")
            Spacer()
        } else if let error = contactsError {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 50))
                    .foregroundColor(.gray)
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.gray)
                    .padding()
            }
            Spacer()
        } else if registeredUsers.isEmpty {
            Spacer()
            Text("Не найдено зарегистрированных контактов")
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        } else {
            List(registeredUsers) { user in
                Button {
                    withAnimation(Animation.easeInOut(duration: 0.2)) {
                        toggleSelection(user.id)
                    }
                } label: {
                    HStack(spacing: 14) {
                        // Чекбокс
                        Image(systemName: selectedUserIds.contains(user.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(selectedUserIds.contains(user.id) ? .blue : .secondary)
                            .animation(.spring(response: 0.25), value: selectedUserIds.contains(user.id))
                        
                        // Аватар
                        Circle()
                            .fill(Color.blue.opacity(0.2))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Text(String(user.name.prefix(1)))
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
            }
            .listStyle(.plain)
        }
    }
    
    // MARK: - Helpers
    
    private var selectedUsers: [User] {
        registeredUsers.filter { selectedUserIds.contains($0.id) }
    }
    
    private func toggleSelection(_ userId: String) {
        if selectedUserIds.contains(userId) {
            _ = selectedUserIds.remove(userId)
        } else {
            if selectedUserIds.count < 49 { // лимит 50 с учётом создателя
                selectedUserIds.insert(userId)
            }
        }
    }
    
    // MARK: - Load Contacts
    
    private func loadContacts() async {
        isLoadingContacts = true
        
        do {
            let store = CNContactStore()
            let granted = try await store.requestAccess(for: .contacts)
            guard granted else {
                contactsError = "Для поиска друзей разрешите доступ к контактам в настройках"
                isLoadingContacts = false
                return
            }
            
            let rawPhoneNumbers = try await Task.detached(priority: .userInitiated) {
                let keys = [
                    CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor,
                    CNContactPhoneNumbersKey as CNKeyDescriptor
                ]
                
                let request = CNContactFetchRequest(keysToFetch: keys)
                var numbers = Set<String>()
                
                try store.enumerateContacts(with: request) { contact, _ in
                    for phoneVal in contact.phoneNumbers {
                        if let normalized = Self.normalizePhone(phoneVal.value.stringValue) {
                            numbers.insert(normalized)
                        }
                    }
                }
                
                return Array(numbers)
            }.value
            
            guard !rawPhoneNumbers.isEmpty else {
                contactsError = "У вас нет контактов с номерами телефонов"
                isLoadingContacts = false
                return
            }
            
            let users = try await chatService.fetchRegisteredContacts(phoneNumbers: rawPhoneNumbers)
            let currentUserId = SupabaseManager.shared.currentUserId ?? ""
            
            registeredUsers = users
                .filter { $0.id != currentUserId }
                .sorted { $0.name < $1.name }
            
        } catch {
            contactsError = "Ошибка получения контактов: \(error.localizedDescription)"
        }
        
        isLoadingContacts = false
    }
    
    // MARK: - Create Group
    
    private func createGroup() {
        isCreating = true
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = Array(selectedUserIds)
        
        Task {
            do {
                let chat = try await chatService.createGroupChat(
                    name: name,
                    avatarURL: nil,
                    participantIds: ids,
                    context: context
                )
                await MainActor.run {
                    isCreating = false
                    onGroupCreated(chat)
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    errorMessage = "Ошибка создания группы: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - Phone Normalization
    
    private static func normalizePhone(_ phone: String) -> String? {
        var digits = phone.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        guard !digits.isEmpty else { return nil }
        
        if digits.count == 11 && digits.hasPrefix("8") {
            digits.removeFirst()
            digits = "7" + digits
        } else if digits.count == 10 && digits.hasPrefix("9") {
            digits = "7" + digits
        } else if digits.count == 11 && digits.hasPrefix("7") {
            // OK
        } else {
            if digits.count < 10 || digits.count > 15 {
                return nil
            }
        }
        
        return "+" + digits
    }
}
