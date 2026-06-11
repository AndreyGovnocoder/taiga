//
//  ImageCompressor.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 14.03.2026.
//


import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

actor ImageCompressor {
    static let shared = ImageCompressor()
    
    /// Генерирует thumbnail (Data) из оригинала, max 512px, JPEG q=0.6
    func generateThumbnailData(from originalData: Data, maxPixelSize: Int = 512) -> Data? {
        // Попытка 1: ImageIO (быстро, без полного decode)
        if let result = thumbnailViaImageIO(from: originalData, maxPixelSize: maxPixelSize) {
            return result
        }
        
        // Попытка 2: HEIC/проблемный формат → UIImage + UIGraphicsImageRenderer
        guard let uiImage = UIImage(data: originalData) else { return nil }
        let resized = resizeImage(uiImage, maxPixelSize: maxPixelSize)
        // Кодируем через stripAlpha + CGImageDestination (без AlphaPremulLast)
        guard let resizedCG = resized.cgImage,
              let opaqueCG = stripAlpha(from: resizedCG) else { return nil }
        let result = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            result as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, opaqueCG, [
            kCGImageDestinationLossyCompressionQuality: 0.6
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return result as Data
    }
    
    /// Уменьшает изображение до maxPixelSize по большей стороне (если нужно).
    /// Возвращает оригинальный Data если изменение не требуется.
    func resizeIfNeeded(data: Data, maxPixelSize: Int = 1280) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        
        // Проверяем текущий размер
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return data
        }
        
        // Если уже вписывается — не трогаем
        let maxSide = max(width, height)
        if maxSide <= maxPixelSize {
            return data
        }
        
        // Попытка 1: Resize через CGImageSource (быстро, сохраняет EXIF)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            let resizedImage = UIImage(cgImage: cgImage)
            return compressImage(resizedImage, preferHEIC: true) ?? data
        }
        
        // Попытка 2: HEIC fallback через UIGraphicsImageRenderer
        guard let uiImage = UIImage(data: data) else { return data }
        let resized = resizeImage(uiImage, maxPixelSize: maxPixelSize)
        return compressImage(resized, preferHEIC: true) ?? data
    }
    
    /// Сжимает UIImage в HEIC (если поддерживается) или JPEG
    func compressImage(_ image: UIImage, preferHEIC: Bool = true, quality: CGFloat = 0.72) -> Data? {
        if preferHEIC, let heicData = heicData(from: image, quality: quality) {
            return heicData
        }
        // JPEG fallback — тоже через stripAlpha чтобы не было AlphaPremulLast
        guard let cg = image.cgImage, let opaque = stripAlpha(from: cg) else {
            return image.jpegData(compressionQuality: quality)
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return image.jpegData(compressionQuality: quality) }
        CGImageDestinationAddImage(dest, opaque, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return image.jpegData(compressionQuality: quality) }
        return data as Data
    }
    
    // MARK: - Private
    
    /// Чистый thumbnail через ImageIO (без UIImage)
    private func thumbnailViaImageIO(from data: Data, maxPixelSize: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        
        // Перерисовываем через CGContext с явным kCGImageAlphaNoneSkipFirst
        // (UIGraphicsImageRenderer с opaque=true не гарантирует это на всех iOS)
        guard let opaqueImage = stripAlpha(from: cgImage) else { return nil }
        
        let result = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            result as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, opaqueImage, [
            kCGImageDestinationLossyCompressionQuality: 0.6
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return result as Data
    }
    
    /// Resize UIImage через UIGraphicsImageRenderer (opaque, без альфа)
    private func resizeImage(_ image: UIImage, maxPixelSize: Int) -> UIImage {
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return image }
        
        let maxSide = max(originalSize.width, originalSize.height)
        let scale = min(CGFloat(maxPixelSize) / maxSide, 1.0)
        let targetSize = CGSize(
            width: floor(originalSize.width * scale),
            height: floor(originalSize.height * scale)
        )
        
        guard targetSize.width > 0, targetSize.height > 0 else { return image }
        
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: {
            let fmt = UIGraphicsImageRendererFormat()
            fmt.opaque = true  // без альфа → убирает AlphaPremulLast warning
            fmt.scale = 1.0    // пиксели
            return fmt
        }())
        
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
    
    /// Кодирует UIImage в HEIC формат без альфа-канала (opaque RGB)
    private func heicData(from image: UIImage, quality: CGFloat) -> Data? {
        guard let sourceCG = image.cgImage else { return nil }
        
        // Перерисовываем через CGContext с явным kCGImageAlphaNoneSkipFirst
        guard let opaqueImage = stripAlpha(from: sourceCG) else { return nil }
        
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.heic.identifier as CFString, 1, nil
        ) else { return nil }
        
        CGImageDestinationAddImage(destination, opaqueImage, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
    
    /// Перерисовывает CGImage без альфа-канала (kCGImageAlphaNoneSkipFirst).
    /// Гарантированно убирает AlphaPremulLast — в отличие от UIGraphicsImageRenderer(opaque:true).
    private func stripAlpha(from source: CGImage) -> CGImage? {
        let w = source.width
        let h = source.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

// MARK: - Data extension для определения формата

extension Data {
    /// Проверяет, является ли Data файлом HEIC/HEIF по magic bytes
    var isHEIC: Bool {
        guard self.count >= 12 else { return false }
        let ftypRange = self[4..<8]
        guard String(data: ftypRange, encoding: .ascii) == "ftyp" else { return false }
        let brandRange = self[8..<12]
        let brand = String(data: brandRange, encoding: .ascii) ?? ""
        return ["heic", "heix", "mif1", "hevc"].contains(brand)
    }
    
    /// Проверяет, является ли Data файлом PNG по magic bytes (89 50 4E 47)
    var isPNG: Bool {
        guard self.count >= 4 else { return false }
        return self[0] == 0x89 && self[1] == 0x50 && self[2] == 0x4E && self[3] == 0x47
    }
}
