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
    @State private var navigateToChat: Chat? = nil
    
    @State private var showSyncStatus: Bool = true
    @State private var syncStatusTask: Task<Void, Never>? = nil
    
    @State private var selectedTab: ChatTab = .all
    @Namespace private var animation
    
    var body: some View {
        NavigationStack {
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
            .navigationDestination(item: $navigateToChat) { chat in
                ChatDetailView(chat: chat)
            }
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
                        self.navigateToChat = createdChat
                    }
                }
            }
            .sheet(isPresented: $showCreateGroupSheet) {
                CreateGroupView { createdChat in
                    showCreateGroupSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.navigateToChat = createdChat
                    }
                }
            }
            .sheet(isPresented: $showSettingsSheet) {
                SettingsView()
            }
            .onChange(of: viewModel.isLoading) { oldValue, newValue in
                print("DIAG isLoading \(oldValue) -> \(newValue) t=\(Date().timeIntervalSince1970)")
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
            }
        }
        .onChange(of: router.appWakeUpTrigger) { _, _ in
            print("СЕРВЕР: Сигнал пробуждения дошел до списка чатов! Обновляем...")
            Task {
                await viewModel.loadChats(context: context, showLoadingIndicator: false)
            }
        }
        .task(id: router.appWakeUpTrigger) {
            await viewModel.startGlobalSubscription(context: context)
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



