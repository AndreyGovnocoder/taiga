//
//  MessageMigrationPlan.swift
//  MyMessanger
//
//  План миграций схемы SwiftData.
//

import Foundation
import SwiftData

/// План миграций SwiftData.
///
/// V1 → V2: аддитивные опциональные поля (UserDB.avatarURLFull, ChatDB.clearedAt/deletedAt) —
/// `.lightweight` (без потери локального кэша). Будущие breaking-изменения (переименования,
/// смена типов, enum-кейсы `MessageContent`/`ChatType`) добавлять как новую версию + `.custom`.
enum MessageMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [MessageSchemaV1.self, MessageSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: MessageSchemaV1.self, toVersion: MessageSchemaV2.self)
        ]
    }
}
