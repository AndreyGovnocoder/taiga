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
/// Пока одна версия — стадий нет. При следующем breaking-изменении модели:
/// добавить `MessageSchemaV2` в `schemas` и соответствующий `MigrationStage` в `stages`
/// (`.lightweight` для аддитивных правок с дефолтом; `.custom` с `willMigrate`/`didMigrate`
/// для переименований, изменения типов и enum-кейсов `MessageContent`/`ChatType`).
enum MessageMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [MessageSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
