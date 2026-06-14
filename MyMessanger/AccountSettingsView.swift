//
//  AccountSettingsView.swift
//  MyMessanger
//

import SwiftUI
import SwiftData

struct AccountSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    
    @State private var name: String = ""
    @State private var nickname: String = ""
    @State private var phoneNumber: String = ""
    @FocusState private var isInputFocused: Bool
    
    @State private var isSaving: Bool = false
    @State private var isDeleting: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showDeleteConfirmation: Bool = false
    
    var body: some View {
        Form {
            Section("Личные данные") {
                TextField("Имя", text: $name)
                    .textContentType(.name)
                    .focused($isInputFocused)
                
                TextField("Никнейм", text: $nickname)
                    .textContentType(.nickname)
                    .autocapitalization(.none)
                    .focused($isInputFocused)
                
                HStack {
                    Text("Телефон")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(phoneNumber)
                        .foregroundStyle(.primary)
                }
            }
            
            Section {
                NavigationLink {
                    BlockedUsersView()
                } label: {
                    Label("Заблокированные", systemImage: "hand.raised")
                }
            }

            Section {
                Button {
                    logout()
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(.blue)
                        Text("Выйти из аккаунта")
                            .foregroundStyle(.blue)
                    }
                }
            }
            
            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Удалить аккаунт")
                        Spacer()
                        if isDeleting {
                            ProgressView()
                        }
                    }
                }
            } footer: {
                Text("Удаление профиля безвозвратно удалит вашу историю сообщений, чаты и участие в группах.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .interactiveDismissDisabled(isInputFocused)
        .navigationTitle("Аккаунт")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Сохранить") {
                        saveProfile()
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespaces).isEmpty ||
                        nickname.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                }
            }
        }
        .alert("Ошибка", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("ОК") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Вы уверены?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Да, удалить всё", role: .destructive) {
                deleteAccount()
            }
            Button("Отмена", role: .cancel) {}
        }
        .onAppear {
            loadCurrentUserData()
        }
    }
    
    private func loadCurrentUserData() {
        if let user = router.authService.currentUser {
            self.name = user.name
            self.nickname = user.nickname
            self.phoneNumber = user.phoneNumber
        }
    }
    
    private func saveProfile() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                _ = try await router.authService.updateProfile(
                    name: name.trimmingCharacters(in: .whitespaces),
                    nickname: nickname.trimmingCharacters(in: .whitespaces),
                    avatarData: nil
                )
                await MainActor.run {
                    isSaving = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func logout() {
        Task {
            do {
                clearLocalData()
                try await router.authService.logout()
                await MainActor.run {
                    router.state = .auth
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Ошибка при выходе: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func deleteAccount() {
        isDeleting = true
        errorMessage = nil
        Task {
            do {
                // Server-first: сперва удаляем аккаунт на сервере (+выход), и только
                // ПОСЛЕ успеха чистим локальный кэш. Иначе при ошибке RPC получим
                // «аккаунт-зомби»: локально пусто, а на сервере аккаунт жив.
                try await router.authService.deleteAccount()
                clearLocalData()
                await MainActor.run {
                    isDeleting = false
                    router.state = .auth
                }
            } catch {
                // Ничего локального ещё не удалено — состояние восстановимо, можно повторить.
                await MainActor.run {
                    isDeleting = false
                    errorMessage = "Ошибка удаления аккаунта: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func clearLocalData() {
        do {
            try context.delete(model: MessageDB.self)
            try context.delete(model: ChatDB.self)
            try context.delete(model: UserDB.self)
            try context.save()
        } catch {
            Log.error(.db, "СЕРВЕР: Не удалось очистить локальную БД: \(error.localizedDescription)")
        }
    }
}
