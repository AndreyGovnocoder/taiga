//
//  CachedImageView.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 23.03.2026.
//

import SwiftUI
import ImageIO

// MARK: - CachedImageView

/// Переиспользуемый компонент отображения изображений с трёхслойной загрузкой:
/// 1. BlurHash placeholder (мгновенно)
/// 2. Downsampled thumbnail из LocalCache или remote
/// 3. Full-res (только в fullscreen viewer)
struct CachedImageView: View {
    let thumbURL: URL?
    let fullImageURL: URL?
    let blurHash: String?
    let imageWidth: Double?
    let imageHeight: Double?
    
    /// Target display size in points (для downsampling)
    var targetSize: CGSize = CGSize(width: 260, height: 300)
    
    /// Удобный инициализатор для аватарок
    init(avatarURL: URL?, size: CGFloat = 40) {
        self.thumbURL = avatarURL
        self.fullImageURL = nil
        self.blurHash = nil
        self.imageWidth = Double(size)
        self.imageHeight = Double(size)
        self.targetSize = CGSize(width: size, height: size)
    }
    
    /// Полный инициализатор для сообщений
    init(thumbURL: URL?, fullImageURL: URL?, blurHash: String?, imageWidth: Double?, imageHeight: Double?, targetSize: CGSize = CGSize(width: 260, height: 300)) {
        self.thumbURL = thumbURL
        self.fullImageURL = fullImageURL
        self.blurHash = blurHash
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.targetSize = targetSize
    }
    
    @State private var loadedImage: UIImage?
    @State private var blurImage: UIImage?
    @State private var loadTask: Task<Void, Never>?
    
    private var aspectRatio: CGFloat {
        guard let w = imageWidth, let h = imageHeight, w > 0, h > 0 else {
            return 1.0
        }
        return CGFloat(w / h)
    }
    
    /// Вычисленный размер бабла с учётом пропорций и лимитов
    private var displaySize: CGSize {
        let maxW: CGFloat = targetSize.width
        let maxH: CGFloat = targetSize.height
        let ratio = aspectRatio
        
        var w = maxW
        var h = w / ratio
        
        if h > maxH {
            h = maxH
            w = h * ratio
        }
        
        // Для аватаров (маленький targetSize) не применяем минимум 80pt
        let isAvatar = targetSize.width <= 50 && targetSize.height <= 50
        if isAvatar {
            return CGSize(width: w, height: h)
        }
        return CGSize(width: max(w, 80), height: max(h, 80))
    }
    
    var body: some View {
        ZStack {
            // Слой 0: BlurHash placeholder
            if let blurImg = blurImage {
                Image(uiImage: blurImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(.systemBackground)
            }
            
            // Слой 1: Downsampled thumb
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity.animation(.easeIn(duration: 0.2)))
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onAppear {
            decodeBlurHash()
            startLoading()
        }
        .onDisappear {
            loadTask?.cancel()
        }
    }
    
    // MARK: - BlurHash decode (мгновенно, ~3ms)
    
    private func decodeBlurHash() {
        guard let hash = blurHash, !hash.isEmpty, blurImage == nil else { return }
        
        // Защита от nil размеров: если w/h неизвестны, используем стандартные пропорции 3:4
        let hasValidDimensions = imageWidth != nil && imageHeight != nil
            && imageWidth! > 0 && imageHeight! > 0
        
        let blurW: Int
        let blurH: Int
        
        if hasValidDimensions {
            let ratio = CGFloat(imageWidth! / imageHeight!)
            if ratio >= 1.0 {
                blurW = 32
                blurH = max(4, Int(32.0 / ratio))
            } else {
                blurH = 32
                blurW = max(4, Int(32.0 * ratio))
            }
        } else {
            // Fallback: стандартные пропорции 3:4 (портрет)
            blurW = 24
            blurH = 32
        }
        
        blurImage = BlurHash.decode(hash, width: blurW, height: blurH)
    }
    
    // MARK: - Thumb loading (LocalCache → remote)
    
    private func startLoading() {
        guard loadedImage == nil else { return }
        
        loadTask = Task {
            guard let url = thumbURL ?? fullImageURL else { return }

            let scale: CGFloat = 3.0 // Retina @3x — безопасный fallback без deprecated UIScreen.main
            let targetPixelW = Int(displaySize.width * scale)
            let targetPixelH = Int(displaySize.height * scale)
            // Диск — СЫРЫЕ байты оригинала под голым ключом (общий для всех размеров, без
            // повторной загрузки). Память — декод ПОД РАЗМЕР: иначе мелкий декод из списка (50pt)
            // переиспользовался бы крупным профилем (120pt) → пиксельно.
            let diskKey = url.lastPathComponent
            let memKey = "\(diskKey)@\(targetPixelW)x\(targetPixelH)"

            // 1. Проверяем memory cache по size-aware ключу (без await, мгновенно)
            if let memoryImage = LocalCache.shared.cachedImageFromMemory(forKey: memKey) {
                if !Task.isCancelled {
                    loadedImage = memoryImage
                }
                return
            }

            // 2. Проверяем disk cache (сырые байты) → даунсемпл под нужный размер
            if let diskData = await LocalCache.shared.load(forKey: diskKey) {
                let downsampled = downsample(data: diskData, maxWidth: targetPixelW, maxHeight: targetPixelH)
                if !Task.isCancelled, let image = downsampled {
                    loadedImage = image
                    await LocalCache.shared.saveImage(image, forKey: memKey)   // promote под size-aware ключом
                }
                return
            }

            // 3. Загрузка с сервера
            guard url.scheme == "http" || url.scheme == "https" else { return }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if Task.isCancelled { return }

                // Сырые байты на диск под голым ключом (без декода в память — память кэшируем
                // даунсемпленной под memKey ниже).
                await LocalCache.shared.save(data, forKey: diskKey)

                let downsampled = downsample(data: data, maxWidth: targetPixelW, maxHeight: targetPixelH)
                if !Task.isCancelled, let image = downsampled {
                    loadedImage = image
                    await LocalCache.shared.saveImage(image, forKey: memKey)
                }
            } catch {
                print("CachedImageView: Ошибка загрузки \(url): \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Downsampling через ImageIO (экономия памяти)
    
    /// Декодирует изображение сразу в нужный размер через ImageIO,
    /// без промежуточного полноразмерного UIImage (экономия памяти в 4-10x).
    /// При неудаче ImageIO (HEIC) — конвертация через UIImage → JPEG → повторный downsample.
    private func downsample(data: Data, maxWidth: Int, maxHeight: Int) -> UIImage? {
        let maxDimension = max(maxWidth, maxHeight)
        
        // Попытка 1: прямой downsample через ImageIO
        if let image = downsampleViaImageIO(data: data, maxDimension: maxDimension) {
            return image
        }
        
        // Попытка 2: HEIC/проблемный формат → конвертируем в JPEG через UIImage,
        // но рисуем сразу в целевой размер (не полноразмерный decode)
        guard let uiImage = UIImage(data: data) else { return nil }
        
        // Вычисляем целевой размер с сохранением пропорций
        let originalSize = uiImage.size
        guard originalSize.width > 0, originalSize.height > 0 else { return nil }
        
        let scale = min(
            CGFloat(maxWidth) / originalSize.width,
            CGFloat(maxHeight) / originalSize.height,
            1.0 // не увеличиваем
        )
        let targetSize = CGSize(
            width: floor(originalSize.width * scale),
            height: floor(originalSize.height * scale)
        )
        
        // Рисуем в целевой размер с opaque=true (без альфа, экономия памяти)
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: {
            let fmt = UIGraphicsImageRendererFormat()
            fmt.opaque = true
            fmt.scale = 1.0 // пиксели, не поинты
            return fmt
        }())
        
        let resized = renderer.image { _ in
            uiImage.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        
        return resized
    }
    
    /// Чистый downsample через ImageIO без промежуточного UIImage
    private func downsampleViaImageIO(data: Data, maxDimension: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return nil
        }
        
        return UIImage(cgImage: cgImage)
    }
}
