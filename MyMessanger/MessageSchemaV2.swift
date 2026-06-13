//
//  MessageSchemaV2.swift
//  MyMessanger
//
//  Версия 2 схемы SwiftData — аддитивные поля (lightweight-миграция от V1).
//

import Foundation
import SwiftData

/// Версия 2 схемы SwiftData. Отличие от V1 — только АДДИТИВНЫЕ опциональные поля:
///   • `UserDB.avatarURLFull` (полноразмерный аватар);
///   • `ChatDB.clearedAt` / `ChatDB.deletedAt` (метки очистки/удаления чата, зеркало сервера).
/// Набор моделей тот же (`[UserDB, MessageDB, ChatDB]`) — поэтому миграция V1→V2 `.lightweight`
/// (новые опциональные колонки добавляются без потери локального кэша). Версия модели — (2,0,0).
enum MessageSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [UserDB.self, MessageDB.self, ChatDB.self]
    }
}
