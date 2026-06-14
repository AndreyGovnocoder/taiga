//
//  ContentView.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 09.03.2026.
//

import SwiftUI
import Supabase

enum ChatTab {
    case all, privateChats, groups
}

struct ContentView: View
{
    @State private var viewModel = ContentViewModel()
    @Environment(AppRouter.self) var router
    @Environment(\.modelContext) private var context
    
    @State private var showSettingsSheet: Bool = false
    

    @State private var showContactsSheet: Bool = false
    @State private var showCreateGroupSheet: Bool = false
    @State private var chatPath: [Chat] = []
    @State private var chatToDelete: Chat? = nil
    
    @State private var showSyncStatus: Bool = true
    @State private var syncStatusTask: Task<Void, Never>? = nil
    
    @State private var selectedTab: ChatTab = .all
    @Namespace private var animation
    
    var body: some View {
        NavigationStack(path: $chatPath) {
            VStack(spacing: 0) {
                // Главный переключатель табов
                HStack(spacing: 0) {
                    tabButton(title: "Все", tab: .all, count: viewModel.totalUnreadCount)
                    tabButton(title: "Личные", tab: .privateChats, count: viewModel.privateUnreadCount)
                    tabButton(title: "Группы", tab: .groups, count: viewModel.groupUnreadCount)
                }
                .padding(.top, 8)
                .background(Color(.systemBackground))
                
                Divider()
                
                // Экраны (свайпаются Native)
                TabView(selection: $selectedTab) {
                    chatList(for: viewModel.chats)
                        .tag(ChatTab.all)
                    
                    chatList(for: viewModel.privateChats)
                        .tag(ChatTab.privateChats)
                    
                    chatList(for: viewModel.groupChats)
                        .tag(ChatTab.groups)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .overlay {
                if let errorMessage = viewModel.errorMessage {
                    ContentUnavailableView {
                        Label("Ошибка загрузки", systemImage: "exclamationmark.triangle.fill")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Повторить") {
                            Task { await viewModel.loadChats(context: context) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if viewModel.chats.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView(
                        "У вас в Тайге нет чатов",
                        systemImage: "message",
                        description: Text("Нажмите на кнопку справа внизу, чтобы начать общение в Тайге")
                    )
                }
            }
            
            .navigationTitle("Чаты")
            .navigationDestination(for: Chat.self) { chat in
                ChatDetailView(chat: chat)
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        showSettingsSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 28))
                            .foregroundColor(.blue)
                            .frame(width: 44, height: 44)
                    }
                    
                    Spacer()
                    
                    Group {
                        if viewModel.isLoading {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Обновление...")
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        } else if showSyncStatus {
                            Text("Синхронизировано")
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.green)
                    .animation(.easeInOut(duration: 0.3), value: viewModel.isLoading)
                    .animation(.easeInOut(duration: 0.3), value: showSyncStatus)
                    
                    Spacer()
                    
                    Menu {
                        Button("Новый чат", systemImage: "person.fill") {
                            showContactsSheet = true
                        }
                        Button("Создать группу", systemImage: "person.3.fill") {
                            showCreateGroupSheet = true
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .background(.bar)
                .overlay(Rectangle().frame(height: 0.33).foregroundColor(Color(UIColor.separator)), alignment: .top)
            }
            
            .sheet(isPresented: $showContactsSheet) {
                ContactsView { createdChat in
                    showContactsSheet = false
                    // Небольшая задержка, чтобы NavigationStack успел закрыть sheet
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.chatPath = [createdChat]
                    }
                }
                // Sheet перекрывает список → он не «виден» (счётчики скрыты), не подавляем баннер.
                .onAppear { SupabaseManager.shared.isChatListVisible = false }
                .onDisappear { SupabaseManager.shared.isChatListVisible = true }
            }
            .sheet(isPresented: $showCreateGroupSheet) {
                CreateGroupView { createdChat in
                    showCreateGroupSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.chatPath = [createdChat]
                    }
                }
                .onAppear { SupabaseManager.shared.isChatListVisible = false }
                .onDisappear { SupabaseManager.shared.isChatListVisible = true }
            }
            .sheet(isPresented: $showSettingsSheet) {
                SettingsView()
                    .onAppear { SupabaseManager.shared.isChatListVisible = false }
                    .onDisappear { SupabaseManager.shared.isChatListVisible = true }
            }
            .onChange(of: viewModel.isLoading) { oldValue, newValue in
                if newValue {
                    syncStatusTask?.cancel()
                    withAnimation { showSyncStatus = true }
                } else {
                    syncStatusTask?.cancel()
                    syncStatusTask = Task {
                        try? await Task.sleep(nanoseconds: 8_000_000_000)
                        
                        if !Task.isCancelled {
                            await MainActor.run {
                                withAnimation { showSyncStatus = false }
                            }
                        }
                    }
                }
            }

            .task {
                await viewModel.loadChats(context: context, showLoadingIndicator: true)
                viewModel.ensureGlobalSubscription(context: context)
                // Cold-launch deep-link (BUG 2): пуш мог быть тапнут ДО монтирования
                // ContentView (когда .onReceive ещё не подписан) → подхватываем отложенный
                // chat_id здесь, после первичной загрузки чатов.
                if let pending = SupabaseManager.shared.pendingDeepLinkChatId {
                    handleDeepLink(chatId: pending)
                }
            }
        }
        .onChange(of: router.appWakeUpTrigger) { _, _ in
            Log.debug(.app, "СЕРВЕР: Сигнал пробуждения дошел до списка чатов! Обновляем...")
            Task {
                await viewModel.loadChats(context: context, showLoadingIndicator: false)
            }
            // Переподписка через единого владельца (раньше это делал отдельный .task(id:)).
            viewModel.ensureGlobalSubscription(context: context)
        }
        .onChange(of: router.state) { _, newState in
            // Выход/смена аккаунта (state != .main): гасим подписку и наблюдателей,
            // чтобы осиротевший Task не писал в shared mainContext. Навигация в чат
            // НЕ меняет router.state (остаётся .main) → подписка не рвётся.
            if newState != .main {
                viewModel.stopGlobalSubscription()
                // Сбрасываем отложенный deep-link при выходе/смене аккаунта, чтобы chat_id
                // прошлого пользователя не подхватился после нового входа.
                SupabaseManager.shared.pendingDeepLinkChatId = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openChatRequested)) { notification in
            // Тёплый путь deep-link (BUG 2): приложение уже запущено, ContentView в дереве.
            if let chatId = notification.object as? String {
                handleDeepLink(chatId: chatId)
            }
        }
        // Список чатов на экране → подавляем foreground-баннер (новое сообщение видно
        // по счётчику). Push-делегат дополнительно проверяет activeChatId == nil, поэтому
        // переход в чат (ContentView остаётся в стеке, isChatListVisible не сбрасывается)
        // не ломает баннеры для других чатов. Сброс на onDisappear = выход/смена аккаунта.
        .onAppear { SupabaseManager.shared.isChatListVisible = true }
        .onDisappear { SupabaseManager.shared.isChatListVisible = false }
        .confirmationDialog(
            "Удалить чат?",
            isPresented: Binding(
                get: { chatToDelete != nil },
                set: { if !$0 { chatToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: chatToDelete
        ) { chat in
            Button("Удалить безвозвратно", role: .destructive) {
                Task { await viewModel.deleteChat(chat, context: context) }
            }
            Button("Отмена", role: .cancel) { }
        } message: { _ in
            Text("Чат, все его сообщения и медиа будут удалены с этого устройства без возможности восстановления.")
        }
    }
    
    /// Deep-link из пуша (BUG 2): открыть чат по chat_id. Резолвим из загруженных чатов
    /// (если ещё не подгружены — один loadChats и повтор), затем заменяем chatPath на [chat] —
    /// тот же стек навигации, что и при открытии созданного чата. Идемпотентно: сразу чистим
    /// pending и не переоткрываем уже активный чат.
    private func handleDeepLink(chatId: String) {
        let target = chatId.lowercased()
        SupabaseManager.shared.pendingDeepLinkChatId = nil

        // Уже открыт этот чат — ничего не делаем.
        if SupabaseManager.shared.activeChatId == target { return }

        Task { @MainActor in
            var chat = viewModel.chats.first { $0.id.lowercased() == target }
            if chat == nil {
                // Чат мог ещё не подгрузиться (cold launch / новый чат) — обновляем и повторяем.
                await viewModel.loadChats(context: context, showLoadingIndicator: false)
                chat = viewModel.chats.first { $0.id.lowercased() == target }
            }
            guard let chat else {
                Log.debug(.deeplink, "DEEP-LINK: чат \(target) не найден локально — не открываем")
                return
            }
            // Атомарная замена стека навигации ровно на [chat] (поверх корня-списка),
            // что бы ни было открыто. Корректно для всех путей, включая «открыт ДРУГОЙ чат»
            // (тапнули пуш для B, читая A → попадаем на B, back ведёт в список, не в A).
            chatPath = [chat]
        }
    }

    @ViewBuilder
    private func chatList(for list: [Chat]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(list) { chat in
                    NavigationLink(value: chat) {
                        ChatRowView(chat: chat)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    // Контекстное меню (long-press): надёжно работает в ScrollView/LazyVStack
                    // (в отличие от .swipeActions — это API List). Удаление — с подтверждением.
                    .contextMenu {
                        Button(role: .destructive) {
                            chatToDelete = chat
                        } label: {
                            Label("Удалить чат", systemImage: "trash")
                        }
                    }

                    Divider()
                        .padding(.leading, 76)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: list.map(\.id))
        }
        .refreshable {
            await viewModel.loadChats(context: context, showLoadingIndicator: false)
        }
    }
    
    @ViewBuilder
    private func tabButton(title: String, tab: ChatTab, count: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(selectedTab == tab ? .semibold : .regular)
                        .foregroundColor(selectedTab == tab ? .blue : .secondary)
                    
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red)
                            .clipShape(Capsule())
                    }
                }
                
                ZStack {
                    Capsule()
                        .fill(Color.clear)
                        .frame(height: 3)
                    
                    if selectedTab == tab {
                        Capsule()
                            .fill(Color.blue)
                            .frame(height: 3)
                            .matchedGeometryEffect(id: "TabIndicator", in: animation)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppRouter())
}



