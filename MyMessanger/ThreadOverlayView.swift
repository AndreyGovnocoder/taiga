//
//  ThreadOverlayView.swift
//  MyMessanger
//
//  Created by Antigravity AI on 22.03.2026.
//

import SwiftUI
import SwiftData
import PhotosUI
import MessagingUI

// MARK: - ThreadOverlayView

/// Полноэкранный overlay для просмотра ветки сообщений.
/// Открывается поверх ChatDetailView с blur + dim фоном.
/// Закрытие: × в правом верхнем углу или тап по фону вне сообщений.
struct ThreadOverlayView: View {
    @Bindable var viewModel: ThreadViewModel
    let autoFocusInput: Bool
    let onDismiss: () -> Void
    var onTapImage: ((URL, URL?, String?, Double?, Double?) -> Void)?
    
    @Environment(\.modelContext) private var context
    @State private var appeared = false
    @State private var scrollPosition = TiledScrollPosition(
        autoScrollsToBottomOnAppend: true,
        scrollsToBottomOnReplace: true
    )
    @FocusState private var isInputFocused: Bool
    
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var selectedPhotosItems: [PhotosPickerItem] = []
    @State private var selectedPhotos: [SelectedPhoto] = []
    @State private var cameraImagesData: [Data] = []
    @State private var captionText: String = ""
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Blur фон
            Color.clear
                .background(.ultraThinMaterial)
            
            // Контент — сообщения
            VStack(spacing: 0) {
                TiledView(
                    dataSource: viewModel.dataSource,
                    scrollPosition: $scrollPosition
                ) { threadItem in
                    ThreadMessageCell(
                        item: threadItem.message,
                        showDateSeparator: threadItem.showDateSeparator,
                        repliedMessage: threadItem.repliedMessage,
                        repliedSenderName: threadItem.repliedSenderName,
                        senderName: threadItem.senderName,
                        senderAvatar: threadItem.senderAvatar,
                        onReply: { msg in
                            viewModel.replyToMessage = msg
                            isInputFocused = true
                        },
                        onTapImage: { imageURL, thumbURL, blurHash, width, height in
                            onTapImage?(imageURL, thumbURL, blurHash, width, height)
                        },
                        onRetry: {
                            Task {
                                await viewModel.retryImageMessage(threadItem.message)
                            }
                        }
                    )
                }
                .prependLoader(.loader(perform: {
                    viewModel.loadOlder()
                }) {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Загрузка сообщений...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                })
                .onTapBackground {
                    dismiss()
                }
                .onDragIntoBottomSafeArea {
                    isInputFocused = false
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let replyMsg = viewModel.replyToMessage {
                        ThreadReplyBar(
                            message: replyMsg,
                            senderName: senderName(for: replyMsg)
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.replyToMessage = nil
                            }
                        }
                    }
                    
                    if !selectedPhotos.isEmpty {
                        threadImageStripPreview
                    }
                    
                    threadInputBar
                }
            }
            .opacity(appeared ? 1 : 0)
            
            // Кнопка закрытия
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.8))
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }
            .padding(.top, 12)
            .padding(.trailing, 16)
        }
        .onAppear {
            viewModel.loadThread(context: context)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                appeared = true
            }
            if autoFocusInput {
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    isInputFocused = true
                }
            }
        }
        .sheet(isPresented: $showAttachMenu) {
            AttachmentMenuSheet(
                onPhoto: { showPhotoPicker = true },
                onCamera: { showCamera = true }
            )
            .presentationDetents([.height(140)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(20)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotosItems, maxSelectionCount: 10, matching: .images)
        .onChange(of: selectedPhotosItems) { _, newItems in
            let newPhotos = newItems.map { SelectedPhoto(pickerItem: $0) }
            selectedPhotos.append(contentsOf: newPhotos)
            selectedPhotosItems = []
            
            for i in (selectedPhotos.count - newPhotos.count)..<selectedPhotos.count {
                guard let item = selectedPhotos[i].pickerItem else { continue }
                let index = i
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let thumbData = await ImageCompressor.shared.generateThumbnailData(from: data, maxPixelSize: 200) ?? data
                        if index < selectedPhotos.count {
                            if let uiImg = UIImage(data: thumbData) {
                                selectedPhotos[index].thumbnail = Image(uiImage: uiImg)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(selectedImagesData: $cameraImagesData)
        }
        .onChange(of: cameraImagesData) { _, newData in
            for data in newData {
                let photo = SelectedPhoto(cameraData: data)
                selectedPhotos.append(photo)
            }
            cameraImagesData = []
        }
    }
    
    // MARK: - Input Bar
    
    private var threadInputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                showAttachMenu = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .padding(.bottom, 6)
            
            // Многострочное поле ввода
            ZStack(alignment: .topLeading) {
                if threadInputTextBinding.wrappedValue.isEmpty {
                    Text(selectedPhotos.isEmpty ? "Ответить в ветке..." : "Подпись к фото...")
                        .foregroundStyle(.placeholder)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                
                TextEditor(text: threadInputTextBinding)
                    .focused($isInputFocused)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .frame(minHeight: 36, maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            
            Button {
                handleThreadSend()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(canThreadSend ? .blue : .gray)
            }
            .disabled(!canThreadSend)
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
    
    private var canThreadSend: Bool {
        if !selectedPhotos.isEmpty {
            return selectedPhotos.allSatisfy { $0.thumbnail != nil }
        }
        return !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var threadInputTextBinding: Binding<String> {
        if selectedPhotos.isEmpty {
            return Binding(
                get: { viewModel.inputText },
                set: { viewModel.inputText = $0 }
            )
        } else {
            return $captionText
        }
    }
    
    private func handleThreadSend() {
        if !selectedPhotos.isEmpty {
            let photos = selectedPhotos
            let caption = captionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : captionText
            let vm = viewModel
            selectedPhotos = []
            captionText = ""
            Task {
                var datas: [Data] = []
                await withTaskGroup(of: (Int, Data?).self) { group in
                    for (i, photo) in photos.enumerated() {
                        group.addTask {
                            let data = await photo.loadFullData()
                            return (i, data)
                        }
                    }
                    var results = [(Int, Data?)]()
                    for await result in group {
                        results.append(result)
                    }
                    results.sort { $0.0 < $1.0 }
                    datas = results.compactMap { $0.1 }
                }
                if !datas.isEmpty {
                    await vm.sendMediaMessages(datas: datas, caption: caption)
                    scrollPosition.scrollTo(edge: .bottom, animated: true)
                }
            }
        } else {
            Task {
                await viewModel.sendMessage()
                scrollPosition.scrollTo(edge: .bottom, animated: true)
            }
        }
    }
    
    // MARK: - Image Strip Preview (Thread)
    
    @ViewBuilder
    private var threadImageStripPreview: some View {
        let strip = ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selectedPhotos) { photo in
                    threadStripThumbnail(photo: photo)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        strip
    }
    
    @ViewBuilder
    private func threadStripThumbnail(photo: SelectedPhoto) -> some View {
        ZStack(alignment: .topTrailing) {
            if let thumb = photo.thumbnail {
                thumb
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.systemGray4))
                    .frame(width: 64, height: 64)
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedPhotos.removeAll { $0.id == photo.id }
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            .offset(x: 4, y: -4)
        }
    }
    
    // MARK: - Helpers
    
    private func senderName(for message: Message) -> String {
        if message.isCurrentUser { return "Вы" }
        return viewModel.participants.first(where: { $0.id == message.senderId })?.name ?? "Собеседник"
    }
    
    // MARK: - Dismiss
    
    private func dismiss() {
        isInputFocused = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            appeared = false
        }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            onDismiss()
        }
    }
}

// MARK: - ThreadMessageCell (TiledCellContent)

/// Ячейка сообщения в ветке для TiledView.
/// С date separators и reply preview, без thread counts.
struct ThreadMessageCell: TiledCellContent {
    typealias StateValue = Void
    
    let item: Message
    let showDateSeparator: Bool
    let repliedMessage: Message?
    let repliedSenderName: String?
    let senderName: String?
    let senderAvatar: URL?
    var onReply: ((Message) -> Void)?
    var onTapImage: ((URL, URL?, String?, Double?, Double?) -> Void)?
    var onRetry: (() -> Void)?
    
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
    
    func body(context: CellContext<Void>) -> some View {
        VStack(spacing: 0) {
            // Разделитель по дате
            if showDateSeparator {
                DateSeparatorView(date: item.createdAt)
            }
            
            // Бабл
            HStack(alignment: .bottom, spacing: 6) {
                if item.isCurrentUser {
                    Spacer(minLength: 60)
                } else if senderName != nil {
                    if let avatarURL = senderAvatar {
                        CachedImageView(avatarURL: avatarURL, size: 28)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(Color.blue.opacity(0.2))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Text(String(senderName!.prefix(1)))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.blue)
                            )
                    }
                }
                
                VStack(alignment: item.isCurrentUser ? .trailing : .leading, spacing: 2) {
                    // Имя отправителя (только для групповых чатов)
                    if let senderName, !item.isCurrentUser {
                        Text(senderName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(senderColor(for: item.senderId))
                            .padding(.horizontal, 4)
                    }
                    
                    // Контент бабла
                    VStack(alignment: item.isCurrentUser ? .trailing : .leading, spacing: 0) {
                        // Цитата
                        if let replied = repliedMessage {
                            ReplyPreviewInBubble(
                                repliedMessage: replied,
                                senderName: repliedSenderName ?? "Собеседник",
                                isCurrentUser: item.isCurrentUser
                            )
                        }
                        
                        switch item.content {
                        case .text(let text):
                            Text(text)
                                .font(.body)
                                .foregroundStyle(item.isCurrentUser ? .white : .primary)
                                // fixedSize: тело-Text — сосед цитаты в VStack. TiledView меряет высоту
                                // ячейки сжатием (systemLayoutSizeFitting), иначе многострочный ответ
                                // недосчитывается и усекается «...». См. MessageBubbleView.textContent.
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        case .image(let imageURL, let thumbURL, let caption, let width, let height, let blurHash):
                            VStack(alignment: .leading, spacing: 0) {
                                CachedImageView(
                                    thumbURL: thumbURL ?? imageURL,
                                    fullImageURL: imageURL,
                                    blurHash: blurHash,
                                    imageWidth: width,
                                    imageHeight: height
                                )
                                .overlay {
                                    if UploadProgressManager.shared.progress[item.id] != nil {
                                        let progress = UploadProgressManager.shared.getProgress(for: item.id) ?? 0
                                        Color.black.opacity(0.35)
                                        CircularProgressView(progress: progress)
                                            .frame(width: 44, height: 44)
                                    }
                                    
                                    if item.status == .failed {
                                        Color.black.opacity(0.45)
                                        Button {
                                            onRetry?()
                                        } label: {
                                            Image(systemName: "arrow.clockwise.circle.fill")
                                                .font(.system(size: 36))
                                                .foregroundStyle(.white)
                                                .symbolRenderingMode(.hierarchical)
                                        }
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onTapImage?(imageURL, thumbURL, blurHash, width, height)
                                }
                                
                                if let caption, !caption.isEmpty {
                                    Text(caption)
                                        .font(.body)
                                        .foregroundStyle(item.isCurrentUser ? .white : .primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 10)
                                        .padding(.top, 4)
                                        .padding(.bottom, 6)
                                }
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(threadBubbleColor)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    
                    // Время
                    Text(Self.timeFormatter.string(from: item.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .animation(
                    .spring(response: 0.45, dampingFraction: 0.65, blendDuration: 0.1),
                    value: UploadProgressManager.shared.progress[item.id] == nil
                )
                
                if !item.isCurrentUser {
                    Spacer(minLength: 60)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
        }
    }
    
    /// Цвет фона пузыря: прозрачный для image-only, цветной для остальных
    private var threadBubbleColor: Color {
        let isImageOnly: Bool
        switch item.content {
        case .image(_, _, let caption, _, _, _):
            isImageOnly = (caption == nil || caption!.isEmpty) && repliedMessage == nil
        default:
            isImageOnly = false
        }
        
        if isImageOnly { return .clear }
        
        if item.status == .failed { return .red }
        return item.isCurrentUser ? .blue : Color(.systemGray5)
    }
    
    private static let senderColors: [Color] = [
        .red, .orange, .purple, .teal, .pink, .indigo, .mint, .cyan
    ]
    
    private func senderColor(for senderId: String) -> Color {
        let hash = abs(senderId.hashValue)
        return Self.senderColors[hash % Self.senderColors.count]
    }
}

// MARK: - ThreadReplyBar

/// Мини-бар предпросмотра ответа в thread view
struct ThreadReplyBar: View {
    let message: Message
    let senderName: String
    let onCancel: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.blue)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(senderName + ":")
                    .font(.body)
                    .fontWeight(.bold)
                    .foregroundStyle(.blue)

                Text(previewText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2...4)
            }

            Spacer(minLength: 4)

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }
    
    private var previewText: String {
        switch message.content {
        case .text(let text): return text
        case .image(_, _, let text, _, _, _): return text ?? "📷 Фото"
        }
    }
}
