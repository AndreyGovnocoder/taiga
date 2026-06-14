//
//  Log.swift
//  MyMessanger
//
//  Централизованное логирование поверх Apple unified logging (os.Logger).
//

import Foundation
import os

/// Единая точка логирования. Зачем os.Logger вместо bare print():
/// - print() пишет в консоль И в Release-сборке (компилятор его не вырезает), не имеет уровней
///   и не фильтруется по подсистеме/категории.
/// - os.Logger: уровни (.debug не персистится в Release), фильтрация в Console.app/Xcode по
///   subsystem `com.guliy.MyMessanger` и категории, единый формат.
///
/// Call-site принимает ОБЫЧНУЮ Swift-строку (через `@autoclosure () -> String`). Это намеренно:
/// интерполяция на месте вызова — такая же, как у прежних `print(...)` (через `String(describing:)`
/// для любых типов), поэтому миграция `print` → `Log` не вводит риск типобезопасной интерполяции
/// os.Logger (где, например, `\(error)` для голого `Error` не компилируется). Готовая строка
/// логируется с `privacy: .public`: чувствительные данные (APNs-токен, UUID, никнейм) НЕ логируем
/// вовсе (убраны в местах вызова), а не маскируем — поэтому раскрытие .public безопасно.
///
/// Все члены `nonisolated`: проект собран с `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`, и логировать
/// нужно из любого контекста (actor LocalCache, фоновые Task, делегаты уведомлений).
enum Log {

    /// Категории = значение `category` в os.Logger. Используются для фильтрации в консоли.
    enum Category: String {
        case app        // жизненный цикл приложения, пробуждение
        case server     // общие серверные операции (SupabaseManager / прочее)
        case ui         // обновления вью, TiledView, refresh
        case sync       // догон пропущенных событий (SYNC)
        case realtime   // realtime-канал global_messages, подписки
        case chat       // отправка/доставка/ретрай/редактирование/удаление сообщений
        case db         // локальное хранилище (SwiftData / DatabaseService)
        case media      // загрузка/сохранение/удаление картинок и медиа
        case auth       // аутентификация и профиль
        case push       // пуш-уведомления, APNs
        case deeplink   // deep-link по тапу на пуш
    }

    nonisolated private static let subsystem = Bundle.main.bundleIdentifier ?? "com.guliy.MyMessanger"

    nonisolated private static let appLog      = Logger(subsystem: subsystem, category: Category.app.rawValue)
    nonisolated private static let serverLog   = Logger(subsystem: subsystem, category: Category.server.rawValue)
    nonisolated private static let uiLog        = Logger(subsystem: subsystem, category: Category.ui.rawValue)
    nonisolated private static let syncLog      = Logger(subsystem: subsystem, category: Category.sync.rawValue)
    nonisolated private static let realtimeLog  = Logger(subsystem: subsystem, category: Category.realtime.rawValue)
    nonisolated private static let chatLog      = Logger(subsystem: subsystem, category: Category.chat.rawValue)
    nonisolated private static let dbLog        = Logger(subsystem: subsystem, category: Category.db.rawValue)
    nonisolated private static let mediaLog     = Logger(subsystem: subsystem, category: Category.media.rawValue)
    nonisolated private static let authLog      = Logger(subsystem: subsystem, category: Category.auth.rawValue)
    nonisolated private static let pushLog       = Logger(subsystem: subsystem, category: Category.push.rawValue)
    nonisolated private static let deeplinkLog   = Logger(subsystem: subsystem, category: Category.deeplink.rawValue)

    nonisolated private static func logger(for category: Category) -> Logger {
        switch category {
        case .app:      return appLog
        case .server:   return serverLog
        case .ui:       return uiLog
        case .sync:     return syncLog
        case .realtime: return realtimeLog
        case .chat:     return chatLog
        case .db:       return dbLog
        case .media:    return mediaLog
        case .auth:     return authLog
        case .push:     return pushLog
        case .deeplink: return deeplinkLog
        }
    }

    /// Отладочная «крошка». В Release не персистится; в консоли видна при подключённом отладчике.
    nonisolated static func debug(_ category: Category, _ message: @autoclosure @escaping () -> String) {
        logger(for: category).debug("\(message(), privacy: .public)")
    }

    /// Информационное событие (операционная веха, напр. результат sync).
    nonisolated static func info(_ category: Category, _ message: @autoclosure @escaping () -> String) {
        logger(for: category).info("\(message(), privacy: .public)")
    }

    /// Заметное, но не ошибочное событие (стоит видеть в Release-логах).
    nonisolated static func notice(_ category: Category, _ message: @autoclosure @escaping () -> String) {
        logger(for: category).notice("\(message(), privacy: .public)")
    }

    /// Ошибка (сохраняется, помечается уровнем error в Console).
    nonisolated static func error(_ category: Category, _ message: @autoclosure @escaping () -> String) {
        logger(for: category).error("\(message(), privacy: .public)")
    }
}
