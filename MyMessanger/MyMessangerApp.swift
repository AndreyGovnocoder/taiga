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
    
    // Современный метод обработки фонового (Silent) пуша
    nonisolated func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        
        print("СЕРВЕР: Получен Silent Push! Приложение разбужено в фоне")
        
        // 1. Проверяем, есть ли нужные данные в словаре
        guard let customPayload = userInfo as? [String: Any],
              let messageIdStr = customPayload["message_id"] as? String,
              let _ = UUID(uuidString: messageIdStr) else {
            return .noData
        }
        
        // 2. Инициируем фоновую задачу для ModelActor (DatabaseService)
        // В реальном проекте мы бы сделали точечный запрос к БД для получения именно этого сообщения,
        // но так как у тебя уже есть подписка на реалтайм или мы можем дернуть fetchMessages:
        
        // ВАЖНО: Возвращаем .newData, чтобы iOS знала, что мы успешно стянули данные
        // и не пессимизировала нам фоновое время в будущем
        
        return .newData
        
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
    
    // Показывать пуш, даже если приложение открыто
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner, .sound, .badge, .list]
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
    
    var sharedModelContainer: ModelContainer = {
        // Версионированная схема (база миграций). Сегодня no-op относительно прежней
        // Schema([...]) тех же моделей — формат хранения не меняется. Будущие правки @Model
        // добавляются как SchemaV2 + MigrationStage (мигрируемо, без потери локального кэша).
        let schema = Schema(versionedSchema: MessageSchemaV1.self)
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, migrationPlan: MessageMigrationPlan.self, configurations: [modelConfiguration])
        } catch {
            // Последний рубеж: повреждение/несовместимая миграция не должны делать запуск
            // невозможным. Логируем причину ДО сброса (иначе кэш теряется молча), затем
            // пересоздаём пустую БД (данные — кэш сервера, восстановимы при следующей синхронизации).
            print("SwiftData: ⚠️ Не удалось открыть хранилище (\(error)). Сбрасываем локальный кэш и пересоздаём БД.")
            let storeURL = modelConfiguration.url
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: storeURL.deletingPathExtension().appendingPathExtension("sqlite-shm"))
            try? FileManager.default.removeItem(at: storeURL.deletingPathExtension().appendingPathExtension("sqlite-wal"))

            do {
                return try ModelContainer(for: schema, migrationPlan: MessageMigrationPlan.self, configurations: [modelConfiguration])
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




