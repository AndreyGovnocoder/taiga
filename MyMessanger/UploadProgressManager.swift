//
//  UploadProgressManager.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 21.03.2026.
//

import Foundation
import Observation

/// Менеджер прогресса загрузки изображений.
/// Singleton, @Observable — SwiftUI автоматически обновляет View при изменении прогресса.
@Observable
final class UploadProgressManager {
    static let shared = UploadProgressManager()
    
    /// Прогресс загрузки по messageId (0.0...1.0)
    private(set) var progress: [String: Double] = [:]
    
    private init() {}
    
    /// Установить прогресс для конкретного сообщения
    func setProgress(_ value: Double, for messageId: String) {
        progress[messageId] = min(max(value, 0), 1)
    }
    
    /// Получить прогресс (nil = не загружается)
    func getProgress(for messageId: String) -> Double? {
        return progress[messageId]
    }
    
    /// Удалить прогресс (загрузка завершена или отменена)
    func removeProgress(for messageId: String) {
        progress.removeValue(forKey: messageId)
    }
}
