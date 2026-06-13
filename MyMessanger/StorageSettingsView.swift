//
//  StorageSettingsView.swift
//  MyMessanger
//

import SwiftUI
import SwiftData

// MARK: - Модель данных для отображения чата в списке хранилища

struct ChatStorageInfo: Identifiable {
    let id: String
    let name: String
    let avatarURL: URL?
    let type: ChatType
    let messageCount: Int
    let mediaCount: Int
    let estimatedSize: Int64 // в байтах
}

// MARK: - Главный экран хранилища

struct StorageSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var allMessages: [MessageDB]
    @Query private var allChats: [ChatDB]
    @Query private var allUsers: [UserDB]
    
    @State private var chatStorageItems: [ChatStorageInfo] = []
    @State private var isLoading = true
    
    private var totalEstimatedSize: Int64 {
        chatStorageItems.reduce(0) { $0 + $1.estimatedSize }
    }
    
    private var totalMessageCount: Int {
        chatStorageItems.reduce(0) { $0 + $1.messageCount }
    }
    
    private var totalMediaCount: Int {
        chatStorageItems.reduce(0) { $0 + $1.mediaCount }
    }
    
    var body: some View {
        List {
            // MARK: - Общая статистика
            Section {
                HStack {
                    Label {
                        Text("Общий размер кэша")
                    } icon: {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(.blue)
                    }
                    Spacer()
                    Text(formatBytes(totalEstimatedSize))
                        .foregroundStyle(.secondary)
                        .fontWeight(.medium)
                }
                
                HStack {
                    Label {
                        Text("Всего сообщений")
                    } icon: {
                        Image(systemName: "message")
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Text("\(totalMessageCount)")
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Label {
                        Text("Медиафайлов")
                    } icon: {
                        Image(systemName: "photo.on.rectangle")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("\(totalMediaCount)")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Статистика")
            }
            
            // MARK: - Список чатов
            Section {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView("Подсчёт...")
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else if chatStorageItems.isEmpty {
                    Text("Нет данных")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(chatStorageItems.sorted(by: { $0.estimatedSize > $1.estimatedSize })) { item in
                        NavigationLink(destination: ChatStorageDetailView(chatInfo: item)) {
                            ChatStorageRow(info: item)
                        }
                    }
                }
            } header: {
                Text("Чаты")
            } footer: {
                Text("Нажмите на чат для управления его данными.")
            }
        }
        .navigationTitle("Хранилище")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            calculateStorage()
        }
    }
    
    // MARK: - Расчёт хранилища
    
    private func calculateStorage() {
        isLoading = true
        
        var items: [ChatStorageInfo] = []
        
        for chat in allChats {
            let chatId = chat.id
            let messages = allMessages.filter { $0.chatId == chatId && !$0.isHiddenLocally }
            
            let mediaMessages = messages.filter { msg in
                if case .image = msg.content { return true }
                return false
            }
            
            // Примерная оценка:
            // текстовое сообщение ~200 байт, изображение ~150 КБ (кэш + метаданные)
            let textSize = Int64((messages.count - mediaMessages.count) * 200)
            let mediaSize = Int64(mediaMessages.count) * 150_000
            let estimated = textSize + mediaSize
            
            // Определяем имя чата
            let chatName: String
            let chatAvatar: URL?
            let isGroup: Bool
            
            if case .group(let name, let groupAvatar) = chat.type {
                chatName = name
                chatAvatar = groupAvatar
                isGroup = true
            } else {
                isGroup = false
                // Для личного чата — находим собеседника
                let currentUserId = SupabaseManager.shared.currentUserId ?? ""
                let otherUserId = chat.participantIds.first(where: { $0 != currentUserId }) ?? ""
                let otherUser = allUsers.first(where: { $0.id == otherUserId })
                chatName = otherUser?.name ?? "Чат"
                chatAvatar = otherUser?.avatarURL
            }
            
            items.append(ChatStorageInfo(
                id: chat.id,
                name: chatName,
                avatarURL: chatAvatar,
                type: isGroup ? .group(name: chatName, avatarURL: chatAvatar) : .personal,
                messageCount: messages.count,
                mediaCount: mediaMessages.count,
                estimatedSize: estimated
            ))
        }
        
        chatStorageItems = items
        isLoading = false
    }
    
    // MARK: - Форматирование размера
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Строка чата в списке

struct ChatStorageRow: View {
    let info: ChatStorageInfo
    
    private var isGroup: Bool {
        if case .group = info.type { return true }
        return false
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Аватар
            if let url = info.avatarURL {
                CachedImageView(
                    thumbURL: url,
                    fullImageURL: nil,
                    blurHash: nil,
                    imageWidth: 44,
                    imageHeight: 44,
                    targetSize: CGSize(width: 44, height: 44)
                )
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            } else {
                Image(systemName: isGroup ? "person.3.fill" : "person.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.gray.opacity(0.5))
            }
            
            // Инфо
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .font(.body)
                    .lineLimit(1)
                
                Text("\(info.messageCount) сообщ. · \(info.mediaCount) медиа")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Размер
            Text(formatBytes(info.estimatedSize))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Детальный экран управления кэшем конкретного чата

struct ChatStorageDetailView: View {
    let chatInfo: ChatStorageInfo

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private let chatService: ChatServiceProtocol = SupabaseChatService()
    
    @State private var showClearAllConfirmation = false
    @State private var showClearMediaConfirmation = false
    @State private var showClearOlderConfirmation = false
    @State private var monthsThreshold: String = "3"
    @State private var clearOlderMediaOnly = false
    
    @State private var resultMessage: String? = nil
    @State private var isProcessing = false
    
    var body: some View {
        List {
            // MARK: - Информация о чате
            Section {
                HStack {
                    Label("Сообщений", systemImage: "message")
                    Spacer()
                    Text("\(chatInfo.messageCount)")
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Label("Медиафайлов", systemImage: "photo")
                    Spacer()
                    Text("\(chatInfo.mediaCount)")
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Label("Размер кэша", systemImage: "internaldrive")
                    Spacer()
                    Text(formatBytes(chatInfo.estimatedSize))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Информация")
            }
            
            // MARK: - Очистка всего чата
            Section {
                Button(role: .destructive) {
                    showClearAllConfirmation = true
                } label: {
                    HStack {
                        Label("Очистить весь чат", systemImage: "trash")
                        if isProcessing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isProcessing)
                
                Button(role: .destructive) {
                    showClearMediaConfirmation = true
                } label: {
                    Label("Очистить только медиа", systemImage: "photo.badge.minus")
                }
                .disabled(isProcessing)
            } header: {
                Text("Полная очистка")
            } footer: {
                Text("Удаление данных происходит только локально, у собеседника сообщения сохранятся.")
            }
            
            // MARK: - Очистка по давности
            Section {
                HStack {
                    Text("Старше")
                    TextField("3", text: $monthsThreshold)
                        .keyboardType(.numberPad)
                        .frame(width: 50)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text(monthsWord)
                        .foregroundStyle(.secondary)
                }
                
                Toggle("Только медиафайлы", isOn: $clearOlderMediaOnly)
                
                Button(role: .destructive) {
                    showClearOlderConfirmation = true
                } label: {
                    Label(
                        clearOlderMediaOnly ? "Удалить старые медиа" : "Удалить старые сообщения",
                        systemImage: "clock.badge.xmark"
                    )
                }
                .disabled(isProcessing)
            } header: {
                Text("Очистка по давности")
            } footer: {
                let type = clearOlderMediaOnly ? "медиафайлы" : "сообщения"
                Text("Будут удалены \(type) старше \(monthsThreshold) мес. только на вашем устройстве.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(chatInfo.name)
        .navigationBarTitleDisplayMode(.inline)
        
        // MARK: - Подтверждения
        .confirmationDialog(
            "Очистить весь чат?",
            isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Удалить все сообщения", role: .destructive) {
                clearAllMessages()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все \(chatInfo.messageCount) сообщений будут удалены с вашего устройства. Это действие нельзя отменить.")
        }
        
        .confirmationDialog(
            "Очистить медиа?",
            isPresented: $showClearMediaConfirmation,
            titleVisibility: .visible
        ) {
            Button("Удалить все медиафайлы", role: .destructive) {
                clearMediaOnly()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("\(chatInfo.mediaCount) медиафайлов будут удалены с вашего устройства.")
        }
        
        .confirmationDialog(
            "Удалить старые данные?",
            isPresented: $showClearOlderConfirmation,
            titleVisibility: .visible
        ) {
            let type = clearOlderMediaOnly ? "медиафайлы" : "сообщения"
            Button("Удалить \(type) старше \(monthsThreshold) мес.", role: .destructive) {
                clearOlderThanMonths()
            }
            Button("Отмена", role: .cancel) {}
        }
        
        .alert("Готово", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("ОК") {
                resultMessage = nil
                dismiss()
            }
        } message: {
            Text(resultMessage ?? "")
        }
    }
    
    // MARK: - Логика очистки
    
    /// Скрыть все сообщения в чате (isHiddenLocally = true).
    /// Единый источник логики — ChatServiceProtocol.clearChat (та же логика на экране профиля чата).
    private func clearAllMessages() {
        isProcessing = true
        Task {
            do {
                let count = try await chatService.clearChat(chatId: chatInfo.id, context: context)
                resultMessage = "Скрыто сообщений: \(count)"
            } catch {
                resultMessage = "Ошибка: \(error.localizedDescription)"
            }
            isProcessing = false
        }
    }
    
    /// Скрыть только медиа-сообщения (image)
    private func clearMediaOnly() {
        isProcessing = true
        let chatId = chatInfo.id
        
        let descriptor = FetchDescriptor<MessageDB>(
            predicate: #Predicate<MessageDB> { $0.chatId == chatId && $0.isHiddenLocally == false }
        )
        
        do {
            let messages = try context.fetch(descriptor)
            var count = 0
            
            for message in messages {
                if case .image = message.content {
                    message.isHiddenLocally = true
                    count += 1
                }
            }
            
            // Сначала сохраняем — чтобы #Predicate в updateSnapshot видел актуальный isHiddenLocally
            try context.save()
            updateChatSnapshot(chatId: chatId)
            try context.save()
            resultMessage = "Скрыто медиафайлов: \(count)"
        } catch {
            resultMessage = "Ошибка: \(error.localizedDescription)"
        }
        
        isProcessing = false
    }
    
    /// Скрыть сообщения старше N месяцев (опционально только медиа)
    private func clearOlderThanMonths() {
        guard let months = Int(monthsThreshold), months > 0 else {
            resultMessage = "Введите корректное число месяцев."
            return
        }
        
        isProcessing = true
        let chatId = chatInfo.id
        let cutoffDate = Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? Date()
        
        let descriptor = FetchDescriptor<MessageDB>(
            predicate: #Predicate<MessageDB> {
                $0.chatId == chatId && $0.isHiddenLocally == false && $0.createdAt < cutoffDate
            }
        )
        
        do {
            let messages = try context.fetch(descriptor)
            var count = 0
            
            for message in messages {
                if clearOlderMediaOnly {
                    if case .image = message.content {
                        message.isHiddenLocally = true
                        count += 1
                    }
                } else {
                    message.isHiddenLocally = true
                    count += 1
                }
            }
            
            try context.save()
            updateChatSnapshot(chatId: chatId)
            try context.save()
            
            let type = clearOlderMediaOnly ? "медиафайлов" : "сообщений"
            resultMessage = "Скрыто \(type): \(count)"
        } catch {
            resultMessage = "Ошибка: \(error.localizedDescription)"
        }
        
        isProcessing = false
    }
    
    /// Обновить snapshot последнего сообщения в ChatDB
    private func updateChatSnapshot(chatId: String) {
        let chatDescriptor = FetchDescriptor<ChatDB>(
            predicate: #Predicate<ChatDB> { $0.id == chatId }
        )
        if let chat = try? context.fetch(chatDescriptor).first {
            chat.updateSnapshot(context: context)
        }
    }
    
    // MARK: - Склонение слова "месяц"
    
    private var monthsWord: String {
        guard let n = Int(monthsThreshold) else { return "мес." }
        let mod10 = n % 10
        let mod100 = n % 100
        
        if mod100 >= 11 && mod100 <= 19 {
            return "месяцев"
        }
        switch mod10 {
        case 1: return "месяц"
        case 2, 3, 4: return "месяца"
        default: return "месяцев"
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
