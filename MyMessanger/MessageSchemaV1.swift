//
//  MessageSchemaV1.swift
//  MyMessanger
//
//  Версия 1 схемы SwiftData — точка отсчёта для будущих миграций.
//

import Foundation
import SwiftData

/// Версия 1 схемы SwiftData: текущие модели (`UserDB`, `MessageDB`, `ChatDB`).
///
/// Сегодня это **no-op** относительно прежней `Schema([UserDB, MessageDB, ChatDB])` —
/// тот же набор моделей, тот же формат хранения, миграция не запускается.
/// Цель — зафиксировать baseline, чтобы будущие изменения `@Model` добавлялись
/// как `MessageSchemaV2` + `MigrationStage` (мигрируемо и тестируемо, без молчаливого
/// destructive-сброса локального кэша). Особое внимание — enum'ам `MessageContent`
/// и `ChatType` с associated values: изменение кейса требует `.custom` стадии.
enum MessageSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [UserDB.self, MessageDB.self, ChatDB.self]
    }
}
