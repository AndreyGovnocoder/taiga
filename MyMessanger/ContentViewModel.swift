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
    /// Combine-наблюдатели настраиваются один раз (не пересоздаются на каждый рестарт подписки).
    private var observersConfigured = false

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
            // UGC-модерация: обновляем набор заблокированных (для фильтрации чатов/сообщений/
            // контактов) — ДО fetchChats, влияет на фильтрацию. try? — сбой модерации не
            // должен ломать загрузку чатов.
            _ = try? await chatService.fetchBlockedUsers()

            // Свежие данные о чатах с сервера — с авто-retry на ТРАНЗИЕНТНЫХ сетевых сбоях
            // (флапающая/throttled сеть, таймаут по полузависшему сокету). fetchChats
            // идемпотентен (зовётся на каждый refresh) → повтор безопасен.
            // ВАЖНО: идёт ДО syncMessageEvents — это дешёвый денормализованный запрос
            // (последнее сообщение/счётчики), и видимый список должен обновиться сразу, не
            // дожидаясь сканирования message_events (иначе нюанс «список оживает через ~2с»).
            var attempt = 1
            while true {
                do {
                    _ = try await chatService.fetchChats(context: context)
                    break
                } catch {
                    if error.isTransientNetwork && attempt < 3 && !Task.isCancelled {
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

            // Список виден сразу свежими данными.
            self.reloadLocal(context: context)

            withAnimation {
                self.isLoading = false
            }

            // Догонка пропущенных events (удаления/редактирования) — ПОСЛЕ показа списка,
            // чтобы скан message_events не задерживал видимый рефреш. Применённые изменения
            // подтянутся в UI через ModelContext.didSave; явный reloadLocal — страховка.
            if !Task.isCancelled {
                try? await chatService.syncMessageEvents(context: context)
                self.reloadLocal(context: context)
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

    /// ЕДИНЫЙ владелец глобальной realtime-подписки. Все триггеры — первичный показ,
    /// пробуждение (appWakeUpTrigger), обнаружение нового чата — идут СЮДА. Раньше было
    /// ДВА независимых запускателя (`.task(id:)` в ContentView + restartGlobalSubscription),
    /// что поднимало второй `client.channel("global_messages")` → дубль INSERT-хендлеров →
    /// самоусиливающийся цикл рестартов. Теперь — одна `globalSubscriptionTask`.
    ///
    /// Бездедлочно: старую задачу отменяем и НЕ ждём её `.value`. На мёртвом сокете teardown
    /// канала (#4, `unsubscribe` без таймаута в SDK) мог бы зависнуть — ожидание привело бы
    /// к дедлоку, поэтому новая подписка стартует, не дожидаясь завершения старой.
    @MainActor
    func ensureGlobalSubscription(context: ModelContext) {
        setupObservers(context: context)

        globalSubscriptionTask?.cancel()
        globalSubscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Переподключаем realtime (WebSocket мог умереть во сне)
            await self.chatService.reconnectRealtime()
            if Task.isCancelled { return }
            do {
                try await self.chatService.subscribeToAllChats(container: context.container)
            } catch is CancellationError {
                print("СЕРВЕР: Глобальная подписка остановлена")
            } catch {
                print("СЕРВЕР: Ошибка глобальной подписки: \(error)")
            }
        }
    }

    /// Настраивает Combine-наблюдатели ОДИН раз. Раньше пересоздавались на каждый рестарт
    /// подписки (внутри startGlobalSubscription) — лишняя работа и источник путаницы владения.
    @MainActor
    private func setupObservers(context: ModelContext) {
        guard !observersConfigured else { return }
        observersConfigured = true

        // 1. Собственные save на main context
        dbSubscription = NotificationCenter.default.publisher(for: ModelContext.didSave, object: nil)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reloadLocal(context: context)
            }

        // 2. Входящие сообщения от DatabaseService. Сохранение идёт на ТОТ ЖЕ mainContext
        //    (DatabaseService(context: container.mainContext)) и завершается (modelContext.save())
        //    ДО отправки .newMessageSaved, поэтому reloadLocal сразу видит новые строки —
        //    прежняя задержка 0.3с (воркэраунд видимости SQLite) не нужна и лишь добавляла
        //    лаг. К тому же save дополнительно триггерит ModelContext.didSave → reloadLocal.
        newMessageSubscription = NotificationCenter.default.publisher(for: .newMessageSaved)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reloadLocal(context: context)
            }

        // 3. Обнаружен новый чат — перезагружаем с сервера и переподписываемся
        //    через ТОТ ЖЕ единый владелец (не отдельный restart).
        newChatSubscription = NotificationCenter.default.publisher(for: .newChatDetected)
            .receive(on: RunLoop.main)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.loadChats(context: context, showLoadingIndicator: false)
                    self.ensureGlobalSubscription(context: context)
                }
            }
    }

    /// Останавливает подписку и гасит наблюдателей (при выходе/смене аккаунта), чтобы
    /// осиротевший Task не писал в shared mainContext по данным прошлого пользователя.
    @MainActor
    func stopGlobalSubscription() {
        globalSubscriptionTask?.cancel()
        globalSubscriptionTask = nil
        dbSubscription = nil
        newMessageSubscription = nil
        newChatSubscription = nil
        observersConfigured = false
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

    /// Удаляет чат с устройства (сообщения + ChatDB + медиа из кэша) и обновляет список.
    /// Локально-только: чат вернётся пустым, если собеседник пришлёт новое сообщение.
    @MainActor
    func deleteChat(_ chat: Chat, context: ModelContext) async {
        do {
            try await chatService.deleteChat(chatId: chat.id, context: context)
            reloadLocal(context: context)
        } catch {
            print("Ошибка удаления чата: \(error)")
        }
    }
}



