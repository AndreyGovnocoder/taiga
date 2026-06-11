//
//  MediaGalleryView.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 14.03.2026.
//


import SwiftUI
import SwiftData

struct MediaGalleryView: View {
    
    let initialMessage: Message
    let mediaMessages: [Message]
    var namespace: Namespace.ID
    
    @Environment(\.dismiss) private var dismiss
    //@Environment(\.modelContext) private var context
    
    //@Query private var allChatMessages: [MessageDB]
    
    //@State private var mediaMessages: [Message] = []
    @State private var currentMessageId: String?
    
    init(initialMessage: Message, mediaMessages: [Message], namespace: Namespace.ID) {
        self.initialMessage = initialMessage
        self.mediaMessages = mediaMessages
        self.namespace = namespace
        _currentMessageId = State(initialValue: initialMessage.id)
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(mediaMessages) { msg in
                        if case .image(let url, _, _, _, _, _) = msg.content {
                            ZoomableImageView(imageURL: url)
                                .containerRelativeFrame(.horizontal)
                                .id(msg.id)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentMessageId)
            
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 10)
                Spacer()
                
            }
            
        }
        .navigationBarHidden(true)
        //.onAppear {
        //    prepareMedia()
        //}
    }
    /*
    private func prepareMedia() {
        let filtered: [Message] = allChatMessages.map { $0.toDomain() }.filter { msg in
            if case .image = msg.content { return true }
            return false
        }
        
        self.mediaMessages = filtered
        self.currentMessageId = initialMessage.id
    }
    */
}

struct ZoomableImageView: View {
    let imageURL: URL
    
    @State private var uiImage: UIImage? = nil
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let uiImage = uiImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    let delta = value.magnification / lastScale
                                    lastScale = value.magnification
                                    scale = min(max(scale * delta, 1), 5)
                                }
                                .onEnded { _ in
                                    lastScale = 1.0
                                    if scale < 1.0 {
                                        withAnimation(.spring()) {
                                            scale = 1.0
                                            offset = .zero
                                        }
                                    }
                                }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    if scale > 1.0 {
                                        offset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    }
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                    if scale == 1.0 {
                                        withAnimation(.spring()) {
                                            offset = .zero;
                                            lastOffset = .zero
                                        }
                                    }
                                }
                        )
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task(id: imageURL) {
            await loadHighResImage()
        }
    }
    
    private func loadHighResImage() async {
        let key = imageURL.lastPathComponent
        
        let cachedImage = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            if let image = await LocalCache.shared.loadImage(forKey: key) {
                return image.preparingForDisplay() ?? image
            }
            return nil
        }.value
        
        if let img = cachedImage {
            self.uiImage = img
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: imageURL)
            
            let downloadedImage = await Task.detached(priority: .background) { () -> UIImage? in
                await LocalCache.shared.saveImageData(data, forKey: key)
                let img = UIImage(data: data)
                return img?.preparingForDisplay() ?? img
            }.value
            
            if let img = downloadedImage {
                self.uiImage = img
            }
        } catch {
            print("Ошибка загрузки оригинала фото: \(error)")
        }
    }
}
