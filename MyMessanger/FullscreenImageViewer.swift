//
//  FullscreenImageViewer.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 23.03.2026.
//

import SwiftUI

// MARK: - CircularProgressView (upload progress)

/// Circular progress indicator для upload overlay на image bubble.
struct CircularProgressView: View {
    let progress: Double
    
    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: 3)
            
            // Progress arc
            Circle()
                .trim(from: 0, to: CGFloat(min(progress, 1.0)))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.15), value: progress)
            
            // Percentage text
            Text("\(Int(progress * 100))%")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
        }
    }
}

// MARK: - FullscreenImageItem

/// Идентифицируемый элемент для fullScreenCover(item:) — все данные упакованы атомарно.
struct FullscreenImageItem: Identifiable {
    let id = UUID()
    let imageURL: URL
    let thumbURL: URL?
    let blurHash: String?
    let imageWidth: Double?
    let imageHeight: Double?
}

// MARK: - FullscreenImageViewer

/// Полноэкранный просмотр изображения с zoom и drag-to-dismiss.
struct FullscreenImageViewer: View {
    let imageURL: URL
    let thumbURL: URL?
    let blurHash: String?
    let imageWidth: Double?
    let imageHeight: Double?
    let onDismiss: () -> Void
    
    @State private var fullImage: UIImage?
    @State private var isLoading = true
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var backgroundOpacity: Double = 1.0
    @State private var appeared = false
    @State private var showSavedToast = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color.black.opacity(backgroundOpacity * (appeared ? 1.0 : 0.0))
                    .ignoresSafeArea()
                
                // Image content
                if let image = fullImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(x: offset.width + dragOffset.width,
                                y: offset.height + dragOffset.height)
                        .gesture(
                            // Pinch to zoom
                            MagnifyGesture()
                                .onChanged { value in
                                    scale = lastScale * value.magnification
                                }
                                .onEnded { value in
                                    lastScale = max(1.0, min(scale, 5.0))
                                    scale = lastScale
                                    if scale == 1.0 {
                                        withAnimation(.spring(response: 0.3)) {
                                            offset = .zero
                                            lastOffset = .zero
                                        }
                                    }
                                }
                        )
                        .simultaneousGesture(
                            // Drag to pan (when zoomed) or dismiss (when not zoomed)
                            DragGesture()
                                .onChanged { value in
                                    if scale > 1.0 {
                                        offset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    } else {
                                        dragOffset = value.translation
                                        let progress = abs(value.translation.height) / 300
                                        backgroundOpacity = max(0.3, 1.0 - progress)
                                    }
                                }
                                .onEnded { value in
                                    if scale > 1.0 {
                                        lastOffset = offset
                                    } else {
                                        if abs(value.translation.height) > 100 {
                                            onDismiss()
                                        } else {
                                            withAnimation(.spring(response: 0.3)) {
                                                dragOffset = .zero
                                                backgroundOpacity = 1.0
                                            }
                                        }
                                    }
                                }
                        )
                        .gesture(
                            // Double tap to zoom in/out
                            TapGesture(count: 2)
                                .onEnded {
                                    withAnimation(.spring(response: 0.3)) {
                                        if scale > 1.0 {
                                            scale = 1.0
                                            lastScale = 1.0
                                            offset = .zero
                                            lastOffset = .zero
                                        } else {
                                            scale = 2.5
                                            lastScale = 2.5
                                        }
                                    }
                                }
                        )
                } else {
                    // Placeholder: BlurHash или thumb пока грузится full-res
                    CachedImageView(
                        thumbURL: thumbURL,
                        fullImageURL: nil,
                        blurHash: blurHash,
                        imageWidth: imageWidth,
                        imageHeight: imageHeight,
                        targetSize: CGSize(width: geometry.size.width, height: geometry.size.height)
                    )
                    
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                }
            }
        }
        .overlay {
            // UI controls — поверх всех gesture-ов
            VStack {
                HStack {
                    Spacer()
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                            .padding(16)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.top, 50)
                
                Spacer()
                
                if fullImage != nil {
                    HStack {
                        Spacer()
                        ShareLink(item: imageURL) {
                            Image(systemName: "square.and.arrow.up.circle.fill")
                                .font(.system(size: 30))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white)
                                .padding(.vertical, 16)
                                .padding(.trailing, 16)
                        }
                        
                        Button {
                            if let image = fullImage {
                                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                                withAnimation {
                                    showSavedToast = true
                                }
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    withAnimation {
                                        showSavedToast = false
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 30))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white)
                                .padding(16)
                        }
                    }
                }
            }
            .allowsHitTesting(true)
        }
        .opacity(appeared ? 1.0 : 0.0)
        .overlay {
            if showSavedToast {
                VStack {
                    Spacer()
                    Text("Сохранено в Фото")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 80)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) {
                appeared = true
            }
        }
        .task {
            await loadFullImage()
        }
    }
    
    // MARK: - Full-res loading
    
    private func loadFullImage() async {
        let cacheKey = imageURL.lastPathComponent
        
        // 1. Из кэша
        if let cached = await LocalCache.shared.loadImage(forKey: cacheKey) {
            fullImage = cached
            isLoading = false
            return
        }
        
        // 2. Из сети
        guard imageURL.scheme == "http" || imageURL.scheme == "https" else {
            // Локальный файл
            if let data = try? Data(contentsOf: imageURL), let image = UIImage(data: data) {
                fullImage = image
                isLoading = false
            }
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: imageURL)
            await LocalCache.shared.saveImageData(data, forKey: cacheKey)
            if let image = UIImage(data: data) {
                fullImage = image
            }
        } catch {
            print("FullscreenImageViewer: Ошибка загрузки \(error.localizedDescription)")
        }
        
        isLoading = false
    }
}
