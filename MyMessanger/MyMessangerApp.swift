//
//  MyMessangerApp.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 09.03.2026.
//

import SwiftUI
import SwiftData
import UserNotifications
import Supabase

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Общий ModelContainer (ставится из MyMessangerApp.init) — нужен фоновому обработчику пуша,
    /// чтобы писать сообщение в ТОТ ЖЕ mainContext, что и UI (второй контейнер открывать нельзя).
    static var sharedModelContainer: ModelContainer?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:[UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        print("AppDelegate: Мессенджер успешно запущен и готов к настройке сервисов!")
        
        // Запуск мониторинга сети для авторетрая недоставленных сообщений
        _ = NetworkMonitor.shared
        
        // Очистка старого disk-кэша (файлы старше 14 дней)
        Task.detached(priority: .background) {
            await LocalCache.shared.cleanDiskCache(olderThanDays: 14)
        }
        
        UNUserNotificationCenter.current().delegate = self
        
        Task {
            let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            if granted == true {
                await MainActor.run {
                    application.registerForRemoteNotifications()
                }
            }
        }
        
        return true
    }
    
    // Вызывается при успешном получении APNs токена
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenParts = deviceToken.map { data in String(format: "%02.2hhx", data) }
        let tokenString = tokenParts.joined()
        print("СЕРВЕР: APNs Token: \(tokenString)")
        
        // Отправляем токен в Supabase
        Task {
            await SupabaseManager.shared.saveApnsToken(tokenString)
        }
    }
    
    // Фоновая дозагрузка по пушу (нюанс №6): кладём сообщение в общий mainContext ещё ДО
    // открытия приложения, чтобы на форграунде оно уже было локально (не ждать сетевого
    // fetchChats/realtime). BEST-EFFORT: пуш alert-типа (content-available:1), фоновую побудку
    // iOS даёт оппортунистически и может троттлить → УМЕНЬШАЕТ задержку, но не гарантирует её
    // отсутствие на 100%. Детерминированный вариант — Notification Service Extension (отдельно).
    // nonisolated: из non-Sendable userInfo вытаскиваем только message_id (String, Sendable) в
    // неизолированном контексте, затем хоп на MainActor для записи в mainContext. Иначе non-Sendable
    // [AnyHashable: Any] «пересекает» границу актора при заходе в MainActor-реализацию (ошибка в
    // Swift 6 mode). Сама запись в SwiftData-контекст по-прежнему идёт на MainActor (см. хелпер).
    nonisolated func application(_ application: UIApplication,
                                 didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let messageIdStr = userInfo["message_id"] as? String,
              UUID(uuidString: messageIdStr) != nil else {
            return .noData
        }
        return await AppDelegate.handlePushFetch(messageId: messageIdStr)
    }

    // Запись по пушу в общий mainContext — на MainActor (как и раньше, без межпоточных хопов по
    // самому SwiftData-контексту). Принимает уже извлечённый Sendable-String, не non-Sendable dict.
    @MainActor
    private static func handlePushFetch(messageId: String) async -> UIBackgroundFetchResult {
        guard let container = AppDelegate.sharedModelContainer else { return .noData }
        do {
            let inserted = try await SupabaseChatService().fetchAndStoreMessage(messageId: messageId, container: container)
            return inserted ? .newData : .noData
        } catch {
            print("СЕРВЕР: Не удалось дотянуть сообщение по пушу: \(error.localizedDescription)")
            return .failed
        }
    }
    
    private func requestNotificationAuthorization(application: UIApplication) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error = error {
                print("СЕРВЕР: Ошибка при запросе разрешений на пуши: \(error.localizedDescription)")
                return
            }
            
            if granted {
                print("СЕРВЕР: Пользователь разрашил пуш-уведомления")
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            } else {
                print("СЕРВЕР: Пользователь запретил пуш-уведомления")
            }
        }
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("СЕРВЕР: Не удалось получить Device Token: \(error.localizedDescription)")
    }
    
    // Foreground-показ пуша. Вызывается ТОЛЬКО когда приложение активно — поэтому флаги
    // SupabaseManager.shared всегда отражают текущий видимый экран.
    // - Открыт именно этот чат → без баннера/звука, но ОСТАВЛЯЕМ .badge: сообщение уже
    //   в ленте, при этом серверный totalBadge применяется (markAsRead сам не всегда
    //   срабатывает, если пользователь проскроллен вверх) — бейдж не уходит в недосчёт.
    // - Открыт список чатов (и ни один чат не открыт) → только бейдж, баннер лишний
    //   (новое сообщение уже видно по счётчику чата).
    // - Иначе (открыт ДРУГОЙ чат / прочий экран) → обычный баннер.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        let pushChatId = (info["chat_id"] as? String)?.lowercased()

        if let pushChatId, pushChatId == SupabaseManager.shared.activeChatId {
            return [.badge]
        }
        if SupabaseManager.shared.activeChatId == nil && SupabaseManager.shared.isChatListVisible {
            return [.badge]
        }
        return [.banner, .sound, .badge, .list]
    }

    // Тап по пушу → deep-link в конкретный чат (BUG 2). Вызывается, когда пользователь
    // тапнул уведомление (из фона ИЛИ при холодном старте — тогда после didFinishLaunching).
    // chat_id берём из payload (как в willPresent). Кладём в pending-стор (cold launch: вью
    // могло ещё не подписаться на .openChatRequested) И постим событие (warm: вью уже в дереве).
    // @MainActor (дефолтная изоляция, как willPresent) → userInfo читаем на MainActor без
    // переноса non-Sendable dict через границу актора.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let chatId = (info["chat_id"] as? String)?.lowercased() else { return }
        SupabaseManager.shared.pendingDeepLinkChatId = chatId
        NotificationCenter.default.post(name: .openChatRequested, object: chatId)
    }

    private func saveTokenToSupabase(token: String) async {
        guard let currentUserId = SupabaseManager.shared.currentUserId else {
            print("СЕРВЕР: Юзер не авторизован? не можем сохранить токен")
            return
        }
        
        do {
            try await SupabaseManager.shared.client
                .from("users")
                .update(["apns_token": token])
                .eq("id", value: currentUserId)
                .execute()
            
            print("СЕРВЕР: Токен успешно сохранен в Supabase")
        } catch {
            print("СЕРВЕР: Ошибка при сохранении токена в Supabase: \(error.localizedDescription)")
        }
    }
}

@main
struct MyMessangerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate: AppDelegate

    init() {
        // Прокидываем общий контейнер в AppDelegate для фоновой дозагрузки сообщения по пушу.
        AppDelegate.sharedModelContainer = sharedModelContainer
    }

    var sharedModelContainer: ModelContainer = {
        // Текущая схема (V2). Новые поля V2 (avatarURLFull, clearedAt, deletedAt) — аддитивные
        // ОПЦИОНАЛЬНЫЕ, поэтому SwiftData выполняет авто-lightweight-миграцию со старого (V1)
        // store БЕЗ потери локального кэша и БЕЗ явного SchemaMigrationPlan. Явный план УБРАН:
        // он содержал [V1, V2], где обе версии ссылались на одни и те же живые @Model-классы →
        // одинаковый checksum → SwiftData падал при старте с ObjC-исключением
        // "Duplicate version checksums across stages detected." Будущие BREAKING-правки
        // (переименования, смена типов, enum-кейсы MessageContent/ChatType) добавлять как новую
        // VersionedSchema с СОБСТВЕННЫМИ снапшотами моделей + .custom-стадия (и проверять на Mac
        // против реального store — снапшот старой версии обязан точно воспроизвести её checksum).
        let schema = Schema(versionedSchema: MessageSchemaV2.self)
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // Последний рубеж для ВОССТАНОВИМЫХ Swift-ошибок (повреждение файла, провал реальной
            // миграции). NB: дубль-checksum миграции прилетает как ObjC NSException и сюда НЕ
            // попадает (Swift do/catch его не ловит). Чтобы НЕ терять локальный кэш молча — не
            // удаляем store, а ПЕРЕИМЕНОВЫВАЕМ в .backup (восстановимо/диагностируемо) и логируем
            // причину; данные всё равно кэш сервера и доедут при следующей синхронизации.
            print("SwiftData: ⚠️ Не удалось открыть хранилище (\(error)). Сохраняю повреждённый store в .backup и пересоздаю БД.")
            let storeURL = modelConfiguration.url
            let shmURL = storeURL.deletingPathExtension().appendingPathExtension("sqlite-shm")
            let walURL = storeURL.deletingPathExtension().appendingPathExtension("sqlite-wal")
            for url in [storeURL, shmURL, walURL] where FileManager.default.fileExists(atPath: url.path) {
                let backupURL = url.appendingPathExtension("backup")
                try? FileManager.default.removeItem(at: backupURL)        // прежний бэкап, если был
                try? FileManager.default.moveItem(at: url, to: backupURL)
            }

            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Не удалось создать ModelContainer даже после сброса: \(error)")
            }
        }
    }()
    
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(sharedModelContainer)
    }
}




