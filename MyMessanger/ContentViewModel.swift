//
//  ContentViewModel.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 10.03.2026.
//


import SwiftUI
import Foundation
import SwiftData
import Combine

@Observable
class ContentViewModel {
    
    var chats: [Chat] = []
    
    var privateChats: [Chat] { chats.filter { !$0.isGroup } }
    var groupChats: [Chat] { chats.filter { $0.isGroup } }
    
    var totalUnreadCount: Int { chats.reduce(0) { $0 + $1.unreadCount } }
    var privateUnreadCount: Int { privateChats.reduce(0) { $0 + $1.unreadCount } }
    var groupUnreadCount: Int { groupChats.reduce(0) { $0 + $1.unreadCount } }
    
    var isLoading: Bool = true
    var errorMessage: String? = nil
    
    private let chatService: ChatServiceProtocol
    private var dbSubscription: AnyCancellable?
    private var newMessageSubscription: AnyCancellable?
    private var newChatSubscription: AnyCancellable?
    private var globalSubscriptionTask: Task<Void, Never>?
    
    init(chatService: ChatServiceProtocol? = nil) {
        self.chatService = chatService ?? SupabaseChatService()
    }
    
    @MainActor
    func loadChats(context: ModelContext, showLoadingIndicator: Bool = true) async {
        // 1. МГНОВЕННО рендерим локальные чаты!
        self.reloadLocal(context: context)

        // 2. Показываем лоадер (если не silent/pull-to-refresh)
        if showLoadingIndicator && self.chats.isEmpty {
            self.isLoading = true
            self.errorMessage = nil
        }

        // 3. Пытаемся ретраить старые отправки
        await chatService.retryPendingMessages(context: context)

        do {
            // 0. UGC-модерация: обновляем набор заблокированных (для фильтрации чатов/сообщений/контактов).
            //    try? — сбой модерации не должен ломать загрузку чатов.
            _ = try? await chatService.fetchBlockedUsers()

            // 4. Синхронизируем пропущенные events (удаления/редактирования) перед загрузкой чатов
            try? await chatService.syncMessageEvents(context: context)

            // 5. Загружаем свежие данные о чатах с сервера — с авто-retry на ТРАНЗИЕНТНЫХ
            //    сетевых сбоях (флапающая/throttled сеть, таймаут по полузависшему сокету).
            //    fetchChats идемпотентен (зовётся на каждый refresh) → повтор безопасен.
            var attempt = 1
            while true {
                do {
                    _ = try await chatService.fetchChats(context: context)
                    break
                } catch {
                    if Self.isTransientNetworkError(error) && attempt < 3 && !Task.isCancelled {
                        print("СЕРВЕР: Повтор загрузки чатов после сетевого сбоя (попытка \(attempt))")
                        attempt += 1
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        continue
                    }
                    throw error
                }
            }

            // Отмена (исчезновение вью / прерванный свайп): выходим, но СБРАСЫВАЕМ индикатор.
            // Раньше здесь был `return` без isLoading=false → спиннер залипал навсегда.
            if Task.isCancelled {
                self.isLoading = false
                return
            }

            // 6. Обновляем UI свежими данными
            self.reloadLocal(context: context)

            withAnimation {
                self.isLoading = false
            }
        } catch {
            if Task.isCancelled || (error as NSError).code == URLError.cancelled.rawValue {
                print("СЕРВЕР: Загрузка чатов отменена (прерванный свайп). Игнорируем ошибку")
                withAnimation { self.isLoading = false }
                return
            }

            print("Ошибка загрузки чатов: \(error)")
            self.errorMessage = "Не удалось загрузить чаты"
            self.isLoading = false
        }
    }

    /// Транзиентные сетевые сбои, на которых имеет смысл повторить запрос.
    /// -1005 (потеря соединения) типичен для первого запроса по «мёртвому»/QUIC-сокету эмулятора;
    /// повтор по свежему соединению (с откатом на HTTP/2) обычно проходит. Таймаут (-1001)
    /// прилетает от нашего URLSession при зависании запроса (см. SupabaseManager.makeHTTPSession).
    static func isTransientNetworkError(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorNetworkConnectionLost,   // -1005
             NSURLErrorTimedOut,                 // -1001
             NSURLErrorCannotConnectToHost,      // -1004
             NSURLErrorCannotFindHost,           // -1003
             NSURLErrorNotConnectedToInternet:   // -1009
            return true
        default:
            return false
        }
    }
    
    @MainActor
    func startGlobalSubscription(context: ModelContext) async {
        // 1. Собственные save на main context
        dbSubscription = NotificationCenter.default.publisher(for: ModelContext.didSave, object: nil)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reloadLocal(context: context)
            }
        
        // 2. Входящие сообщения от DatabaseService actor
        // Задержка 0.3с даёт SQLite время записать данные, чтобы main context их увидел
        newMessageSubscription = NotificationCenter.default.publisher(for: .newMessageSaved)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self?.reloadLocal(context: context)
                }
            }
        
        // 3. Обнаружен новый чат — перезагружаем с сервера и переподписываемся
        newChatSubscription = NotificationCenter.default.publisher(for: .newChatDetected)
            .receive(on: RunLoop.main)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.loadChats(context: context, showLoadingIndicator: false)
                    self.restartGlobalSubscription(context: context)
                }
            }
        
        // 4. Переподключаем realtime (WebSocket мог умереть во сне)
        await chatService.reconnectRealtime()
        
        do {
            try await chatService.subscribeToAllChats(container: context.container)
        } catch is CancellationError {
            print("СЕРВЕР: Глобальная подписка остановлена")
        } catch {
            print("СЕРВЕР: Ошибка глобальной подписки: \(error)")
        }
    }
    
    /// Перезапуск глобальной подписки (после появления нового чата)
    @MainActor
    func restartGlobalSubscription(context: ModelContext) {
        globalSubscriptionTask?.cancel()
        globalSubscriptionTask = Task {
            await startGlobalSubscription(context: context)
        }
    }
    
    @MainActor
    func reloadLocal(context: ModelContext) {
        do {
            let localChats = try chatService.fetchLocalChats(context: context)
            withAnimation(.easeInOut(duration: 0.3)) {
                self.chats = localChats
            }
        } catch {
            print("Ошибка чтения локальных чатов: \(error)")
        }
    }
}



