//
//  LocalCache.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 11.03.2026.
//


import Foundation
import UIKit

actor LocalCache {
    static let shared = LocalCache()
    
    // Выделенный подкаталог под image-кэш. КРИТИЧНО: не используем корень Caches напрямую —
    // там лежит SQLite-стор системного URLCache (Cache.db/-wal/-shm), который держит ОТКРЫТЫЕ
    // дескрипторы, пока идут загрузки картинок через URLSession.shared. Подметание корня Caches
    // (clearAll/cleanDiskCache) отвязывало бы Cache.db из-под живого sqlite-хэндла →
    // "BUG IN CLIENT OF libsqlite3.dylib: ... vnode unlinked while in use". Свой подкаталог
    // изолирует наши файлы от системного стора: чистим только своё, Cache.db не трогаем.
    private let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    // MARK: - Двухуровневый кэш
    
    /// Memory-кэш (L1): мгновенный доступ, автоочистка при memory pressure.
    /// NSCache потокобезопасен по дизайну (Apple docs), поэтому nonisolated(unsafe) безопасен.
    nonisolated(unsafe) private let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 80 * 1024 * 1024 // ~80MB (cost = bytes of decoded bitmap)
        cache.countLimit = 200
        return cache
    }()
    
    // MARK: - Paths
    
    nonisolated func getPath(forKey key: String) -> URL {
        return cacheDirectory.appendingPathComponent(key)
    }
    
    // MARK: - Raw Data (для не-изображений или raw bytes)
    
    func save(_ data: Data, forKey key: String) {
        let url = getPath(forKey: key)
        try? data.write(to: url)
    }
    
    func load(forKey key: String) -> Data? {
        let url = getPath(forKey: key)
        return try? Data(contentsOf: url)
    }
    
    // MARK: - Image-специфичные методы (L1 memory + L2 disk)
    
    /// Сохранить UIImage в оба уровня кэша
    func saveImage(_ image: UIImage, forKey key: String) {
        // L1: memory
        let cost = estimateCost(for: image)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
        
        // L2: disk (JPEG для совместимости, фон)
        if let data = image.jpegData(compressionQuality: 0.85) {
            let url = getPath(forKey: key)
            try? data.write(to: url)
        }
    }
    
    /// Сохранить Data как изображение в оба уровня кэша  
    func saveImageData(_ data: Data, forKey key: String) {
        // L2: disk
        let url = getPath(forKey: key)
        try? data.write(to: url)
        
        // L1: memory (декодируем сразу)
        if let image = UIImage(data: data) {
            let cost = estimateCost(for: image)
            memoryCache.setObject(image, forKey: key as NSString, cost: cost)
        }
    }
    
    /// Загрузить UIImage: L1 (memory) → L2 (disk) → nil
    func loadImage(forKey key: String) -> UIImage? {
        // L1: memory — мгновенно
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }
        
        // L2: disk
        let url = getPath(forKey: key)
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            return nil
        }
        
        // Promote to L1
        let cost = estimateCost(for: image)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
        
        return image
    }
    
    /// Проверить наличие в memory-кэше (для fast path без await)
    nonisolated func cachedImageFromMemory(forKey key: String) -> UIImage? {
        return memoryCache.object(forKey: key as NSString)
    }
    
    // MARK: - Удаление
    
    func delete(forKey key: String) {
        // L1
        memoryCache.removeObject(forKey: key as NSString)
        
        // L2
        let url = getPath(forKey: key)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            Log.error(.media, "СЕРВЕР: Ошибка удаления файла из кэша: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Очистка
    
    /// Удаляет файлы старше N дней с диска
    func cleanDiskCache(olderThanDays days: Int = 14) {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        
        let expirationDate = Date().addingTimeInterval(-TimeInterval(days * 24 * 60 * 60))
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: resourceKeys,
                options: .skipsHiddenFiles
            )
            
            var deletedCount = 0
            var deletedBytes: Int64 = 0
            
            for fileURL in fileURLs {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                
                if let creationDate = resourceValues.creationDate, creationDate < expirationDate {
                    let fileSize = Int64(resourceValues.fileSize ?? 0)
                    deletedBytes += fileSize
                    deletedCount += 1
                    try fileManager.removeItem(at: fileURL)
                }
            }
            
            if deletedCount > 0 {
                let deletedMB = Double(deletedBytes) / 1024.0 / 1024.0
                Log.debug(.media, "СЕРВЕР: Кэш очищен. Удалено \(deletedCount) файлов (\(String(format: "%.1f", deletedMB)) МБ)")
            }
        } catch {
            Log.error(.media, "Ошибка при очистке кэша: \(error.localizedDescription)")
        }
    }
    
    /// Полная очистка кэша (L1 memory + L2 disk). Вызывается при logout / удалении аккаунта,
    /// чтобы кэшированные аватары и медиа прошлого пользователя не оставались на устройстве
    /// (приватность: следующий пользователь на этом устройстве не должен их видеть).
    func clearAll() {
        memoryCache.removeAllObjects()

        // HTTP-кэш картинок, загруженных через URLSession.shared, чистим ШТАТНЫМ API URLCache,
        // а НЕ удалением его файлов: прямое стирание Cache.db ломало sqlite (см. cacheDirectory).
        // Это покрывает приватность — кэшированные тела ответов прошлого пользователя удаляются.
        URLCache.shared.removeAllCachedResponses()

        let fileManager = FileManager.default
        // cacheDirectory — наш изолированный подкаталог ImageCache, поэтому подметание его
        // содержимого больше НЕ задевает системный Cache.db в корне Caches.
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        var removed = 0
        for url in fileURLs {
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        Log.info(.media, "СЕРВЕР: Локальный кэш очищен при выходе/удалении (\(removed) файлов)")
    }

    /// Общий размер disk-кэша в байтах
    func totalDiskCacheSize() -> Int64 {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return 0 }
        
        return files.reduce(into: Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
    }
    
    // MARK: - Private
    
    private func estimateCost(for image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
