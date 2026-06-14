//
//  MessageBubbleView.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 14.03.2026.
//

import SwiftUI
import MessagingUI

// MARK: - TaigaMessageCell (TiledCellContent)

/// Основная ячейка сообщения для TiledView.
/// Рендерит разделитель по дате над баблом, если `showDateSeparator == true`.
struct TaigaMessageCell: TiledCellContent {
    typealias StateValue = SharedSelectionState
    
    let item: Message
    let showDateSeparator: Bool
    let repliedMessage: Message?
    let repliedSenderName: String?
    let threadCount: Int?
    let senderName: String?
    let senderAvatar: URL?
    let isGroupChat: Bool
    let isFirstFromSender: Bool
    let isLastFromSender: Bool
    var onOpenThread: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onReply: ((Message) -> Void)?
    var onTapImage: ((URL, URL?, String?, Double?, Double?) -> Void)?
    var onRetry: (() -> Void)?
    var onCopy: (() -> Void)?
    var onForward: (() -> Void)?
    var onReport: (() -> Void)?
    var onSelect: (() -> Void)?
    var onEdit: ((Message) -> Void)?
    
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
    
    func body(context: CellContext<SharedSelectionState>) -> some View {
        AnimatableMessageCellWrapper(
            item: item,
            showDateSeparator: showDateSeparator,
            isSelectionMode: context.state.value.isSelectionMode,
            isSelected: context.state.value.selectedIds.contains(item.id),
            isDeleting: context.state.value.deletingIds.contains(item.id),
            content: messageRow(isSelectionMode: context.state.value.isSelectionMode),
            onSelect: onSelect,
            onReply: onReply
        )
    }
    
    /// Строка сообщения: HStack с пузырём и Spacer-ами
    @ViewBuilder
    private func messageRow(isSelectionMode: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            if item.isCurrentUser {
                Spacer(minLength: 60)
            } else if isGroupChat {
                if isLastFromSender {
                    if let avatarURL = senderAvatar {
                        CachedImageView(avatarURL: avatarURL, size: 28)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(Color.blue.opacity(0.2))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Text(String((senderName ?? "U").prefix(1)))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.blue)
                            )
                    }
                } else {
                    // Empty space equivalent to 21pt circle
                    Color.clear.frame(width: 28, height: 28)
                }
            }
            
            VStack(alignment: item.isCurrentUser ? .trailing : .leading, spacing: 2) {
                // Имя отправителя (только для групповых чатов)
                if isGroupChat, isFirstFromSender, let senderName, !item.isCurrentUser {
                    Text(senderName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(senderColor(for: item.senderId))
                        .padding(.horizontal, 4)
                }
                
                if isSelectionMode {
                    // В режиме выбора: без onTapGesture (целый ряд — Button)
                    bubbleContent(isSelectionMode: isSelectionMode)
                } else {
                    bubbleContent(isSelectionMode: isSelectionMode)
                        .onTapGesture {
                            // Тап по сообщению из ветки → открыть thread view
                            if let rootId = item.threadRootId {
                                onOpenThread?(rootId)
                            } else if (threadCount ?? 0) >= 2 {
                                onOpenThread?(item.id)
                            }
                        }
                }
                metaRow
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
    
// MARK: - Animatable Wrapper

/// Обертка для обработки анимации скрытия и чтения Environment
struct AnimatableMessageCellWrapper<Content: View>: View {
    let item: Message
    let showDateSeparator: Bool
    let isSelectionMode: Bool
    let isSelected: Bool
    let isDeleting: Bool
    let content: Content
    
    var onSelect: (() -> Void)?
    var onReply: ((Message) -> Void)?
    
    @Environment(\.updateSelfSizing) private var updateSelfSizing
    
    var body: some View {
        VStack(spacing: 0) {
            // Разделитель по дате (если нужен)
            if showDateSeparator {
                DateSeparatorView(date: item.createdAt)
            }
            
            // Бабл сообщения
            if isSelectionMode {
                // Режим выбора: чекбокс + тап по всей строке
                Button {
                    onSelect?()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? .blue : .secondary)
                            .animation(.spring(response: 0.25), value: isSelected)
                        
                        content
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // Обычный режим: swipe-to-reply + context menu
                SwipeToReplyWrapper(isCurrentUser: item.isCurrentUser) {
                    onReply?(item)
                } content: {
                    content
                }
            }
        }
        .opacity(isDeleting ? 0 : 1)
        .scaleEffect(isDeleting ? 0.8 : 1)
        // Использование fixedSize(horizontal: false, vertical: false) позволяет frame(height) реально сжать контент
        .frame(height: isDeleting ? 0.001 : nil, alignment: .top)
        .clipped()
        .onChange(of: isDeleting) { _, newValue in
            if newValue {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    updateSelfSizing()
                }
            }
        }
    }
}

// MARK: - Bubble Content
    
    @ViewBuilder
    private func bubbleContent(isSelectionMode: Bool) -> some View {
        let contentBody = VStack(alignment: item.isCurrentUser ? .trailing : .leading, spacing: 0) {
            // === Заголовок ветки ===
            // Корень: threadRootId == nil ИЛИ threadRootId == item.id (триггер Supabase проставляет self-reference)
            let isSelfRoot = item.threadRootId == nil || item.threadRootId == item.id
            let isThreadRoot = isSelfRoot && (threadCount ?? 0) >= 2
            let isThreadChild = !isSelfRoot && (threadCount ?? 0) >= 2
            
            if isThreadRoot {
                let answersCount = (threadCount ?? 0) - 1
                threadHeader(answersCount: answersCount)
            } else if isThreadChild {
                threadIconOnly()
            }
            
            // === Цитата (ВСЕГДА если есть reply_to) ===
            if let replied = repliedMessage {
                ReplyPreviewInBubble(
                    repliedMessage: replied,
                    senderName: repliedSenderName ?? "Собеседник",
                    isCurrentUser: item.isCurrentUser
                )
                .onTapGesture {
                    let rootId = item.threadRootId ?? item.id
                    onOpenThread?(rootId)
                }
            }
            
            switch item.content {
            case .text(let text):
                textContent(text: text)
                
            case .image(let imageURL, let thumbURL, let caption, let width, let height, let blurHash):
                imageContent(
                    imageURL: imageURL,
                    thumbURL: thumbURL,
                    caption: caption,
                    width: width,
                    height: height,
                    blurHash: blurHash
                )
            }
        }
        .allowsHitTesting(!isSelectionMode) // Отключаем внутренние тапы в режиме выбора
        .background {
            switch item.content {
            case .image(_, _, let caption, _, _, _):
                let hasCaption = caption != nil && !caption!.isEmpty
                if hasCaption || repliedMessage != nil {
                    // Image с подписью или цитатой — нужен фон
                    RoundedRectangle(cornerRadius: 18)
                        .fill(bubbleColor)
                } else {
                    // Image-only — без фона, изображение само формирует bubble
                    Color.clear
                }
            default:
                RoundedRectangle(cornerRadius: 18)
                    .fill(bubbleColor)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18))
        
        if isSelectionMode {
            contentBody
        } else {
            contentBody
            .contextMenu {
                // Ответить
                Button {
                    onReply?(item)
                } label: {
                    Label("Ответить", systemImage: "arrowshape.turn.up.left")
                }
                
                // Редактировать (своё текстовое ≤ TTL)
                if item.canEdit {
                    Button {
                        onEdit?(item)
                    } label: {
                        Label("Редактировать", systemImage: "pencil")
                    }
                }
                
                // Переслать (заглушка)
                Button {
                    onForward?()
                } label: {
                    Label("Переслать", systemImage: "arrowshape.turn.up.right")
                }
                
                // Копировать
                Button {
                    onCopy?()
                } label: {
                    Label("Копировать", systemImage: "doc.on.doc")
                }
                
                // Сохранить в Фото (только для изображений)
                if case .image(let imageURL, _, _, _, _, _) = item.content {
                    Button {
                        Task {
                            await saveImageToPhotos(url: imageURL)
                        }
                    } label: {
                        Label("Сохранить в Фото", systemImage: "square.and.arrow.down")
                    }
                }
                
                Divider()
                
                // Удалить у всех (своё ≤ TTL)
                if item.canDeleteForEveryone {
                    Button(role: .destructive) {
                        onDelete?()
                    } label: {
                        Label("Удалить у всех", systemImage: "trash")
                    }
                }
                
                // Удалить у себя (всегда доступно)
                Button(role: .destructive) {
                    onDelete?()
                } label: {
                    Label("Удалить у себя", systemImage: "eye.slash")
                }
                
                Divider()
                
                // Пожаловаться (только на чужие сообщения)
                if !item.isCurrentUser {
                    Button(role: .destructive) {
                        onReport?()
                    } label: {
                        Label("Пожаловаться", systemImage: "exclamationmark.bubble")
                    }
                }

                // Выбрать
                Button {
                    onSelect?()
                } label: {
                    Label("Выбрать", systemImage: "checkmark.circle")
                }
            }
        }
    }
    
    /// Заголовок ветки: иконка пузырей + «N ответов»
    private func threadHeader(answersCount: Int) -> some View {
        Button {
            let rootId = item.threadRootId ?? item.id
            onOpenThread?(rootId)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.caption2)
                Text(pluralAnswers(answersCount))
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .foregroundStyle(item.isCurrentUser ? .white.opacity(0.85) : .blue)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }
    
    /// Иконка ветки без количества (для дочерних сообщений)
    private func threadIconOnly() -> some View {
        Button {
            let rootId = item.threadRootId ?? item.id
            onOpenThread?(rootId)
        } label: {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.caption2)
                .foregroundStyle(item.isCurrentUser ? .white.opacity(0.85) : .blue)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
        }
    }
    
    /// Склонение: «1 ответ», «2 ответа», «5 ответов»
    private func pluralAnswers(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        if mod10 == 1 && mod100 != 11 {
            return "\(count) ответ"
        } else if mod10 >= 2 && mod10 <= 4 && !(mod100 >= 12 && mod100 <= 14) {
            return "\(count) ответа"
        } else {
            return "\(count) ответов"
        }
    }
    
    private func textContent(text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(item.isCurrentUser ? .white : .primary)
            // fixedSize: тело-Text — сосед цитаты/заголовка ветки в VStack. TiledView меряет
            // высоту ячейки через systemLayoutSizeFitting (compressed), и без этого многострочный
            // текст ответа недосчитывается по высоте и усекается «...». См. примеры MessagingUI.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
    
    // MARK: - Image Content
    
    @ViewBuilder
    private func imageContent(imageURL: URL, thumbURL: URL?, caption: String?, width: Double?, height: Double?, blurHash: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                CachedImageView(
                    thumbURL: thumbURL ?? imageURL,
                    fullImageURL: imageURL,
                    blurHash: blurHash,
                    imageWidth: width,
                    imageHeight: height
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onTapImage?(imageURL, thumbURL, blurHash, width, height)
                }
                
                // Progress overlay при загрузке — читаем из UploadProgressManager напрямую
                // (item.status может быть stale в TiledView snapshot)
                let uploadProgress = UploadProgressManager.shared.progress[item.id]
                if let progress = uploadProgress {
                    Color.black.opacity(0.35)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    
                    CircularProgressView(progress: progress)
                        .frame(width: 44, height: 44)
                }
                
                // Retry overlay при ошибке — тап для повторной отправки
                if item.status == .failed {
                    Color.black.opacity(0.45)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    
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
            
            // Caption (подпись) под изображением
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
    
    private var bubbleColor: Color {
        if item.isCurrentUser {
            return item.status == .failed ? .red : .blue
        } else {
            return Color(.systemGray5)
        }
    }
    
    /// Генерация цвета из набора для имени отправителя в групповом чате
    private static let senderColors: [Color] = [
        .red, .orange, .purple, .teal, .pink, .indigo, .mint, .cyan
    ]
    
    private func senderColor(for senderId: String) -> Color {
        // Детерминированный хэш по UTF8-байтам (FNV-1a): String.hashValue рандомизирован
        // per-process, иначе цвет участника менялся бы при каждом запуске приложения.
        var hash: UInt64 = 1469598103934665603
        for byte in senderId.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return Self.senderColors[Int(hash % UInt64(Self.senderColors.count))]
    }
    
    // MARK: - Meta Row (время + статус)
    
    private var metaRow: some View {
        HStack(spacing: 4) {
            Text(Self.timeFormatter.string(from: item.createdAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
            
            if item.isCurrentUser {
                statusIcon
            }
        }
        .padding(.horizontal, 4)
    }
    
    // MARK: - Status Icon
    
    @ViewBuilder
    private var statusIcon: some View {
        // Используем UploadProgressManager для определения uploading state,
        // т.к. item.status может быть stale в TiledView snapshot
        let isUploading = UploadProgressManager.shared.progress[item.id] != nil
        
        if isUploading {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)
        } else if item.status == .sending {
            // Часики — сообщение ожидает доставки (как в Telegram)
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if item.status == .sent {
            // Серая одиночная галочка — доставлено на сервер
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if item.status == .delivered {
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(.blue)
        } else if item.status == .read {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.blue)
        } else if item.status == .failed {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Save Image to Photos

/// Загружает изображение по URL (из кэша или сети) и сохраняет в галерею.
func saveImageToPhotos(url: URL) async {
    // 1. Из кэша
    let cacheKey = url.lastPathComponent
    if let cached = await LocalCache.shared.loadImage(forKey: cacheKey) {
        UIImageWriteToSavedPhotosAlbum(cached, nil, nil, nil)
        NotificationCenter.default.post(name: .imageSavedToPhotos, object: nil)
        return
    }
    
    // 2. Локальный файл
    if url.isFileURL {
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            NotificationCenter.default.post(name: .imageSavedToPhotos, object: nil)
        }
        return
    }
    
    // 3. Из сети
    guard url.scheme == "http" || url.scheme == "https" else { return }
    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        if let image = UIImage(data: data) {
            await LocalCache.shared.saveImageData(data, forKey: cacheKey)
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            NotificationCenter.default.post(name: .imageSavedToPhotos, object: nil)
        }
    } catch {
        Log.error(.media, "SaveImage: Ошибка загрузки \(error.localizedDescription)")
    }
}

// MARK: - SwipeToReplyWrapper

/// Обёртка для свайпа влево → reply.
/// Порог: 60pt. Haptic при пересечении. Иконка ↩ за баблом.
struct SwipeToReplyWrapper<Content: View>: View {
    let isCurrentUser: Bool
    let onReply: () -> Void
    @ViewBuilder let content: () -> Content
    
    @State private var offset: CGFloat = 0
    @State private var hasTriggeredHaptic = false
    
    private let replyThreshold: CGFloat = 60
    private let maxDrag: CGFloat = 100
    
    var body: some View {
        ZStack(alignment: .trailing) {
            // Иконка reply — за баблом
            replyIcon
            
            // Контент (бабл)
            content()
                .offset(x: -effectiveOffset)
                .contentShape(Rectangle())
        }
        .gesture(dragGesture)
    }
    
    // MARK: - Reply Icon
    
    private var replyIcon: some View {
        let progress = min(effectiveOffset / replyThreshold, 1.0)
        
        return Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.system(size: 20))
            .foregroundStyle(progress >= 1.0 ? Color.blue : Color.secondary.opacity(0.5))
            .scaleEffect(0.5 + progress * 0.5)
            .opacity(Double(progress))
            .frame(width: 36, height: 36)
            .padding(.trailing, 16)
    }
    
    // MARK: - Effective Offset (rubber band за порогом)
    
    private var effectiveOffset: CGFloat {
        if offset <= replyThreshold {
            return offset
        }
        // Rubber band: замедляем после порога
        let over = offset - replyThreshold
        return replyThreshold + over * 0.3
    }
    
    // MARK: - Drag Gesture
    
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { value in
                // Только свайп влево (отрицательное смещение по X)
                let horizontal = -value.translation.width
                let vertical = abs(value.translation.height)
                
                // Игнорируем если вертикальный свайп (скролл)
                guard horizontal > 0, horizontal > vertical else {
                    return
                }
                
                offset = min(horizontal, maxDrag)
                
                // Haptic при пересечении порога
                if offset >= replyThreshold && !hasTriggeredHaptic {
                    hasTriggeredHaptic = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } else if offset < replyThreshold {
                    hasTriggeredHaptic = false
                }
            }
            .onEnded { _ in
                if offset >= replyThreshold {
                    onReply()
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    offset = 0
                }
                hasTriggeredHaptic = false
            }
    }
}

// MARK: - ReplyPreviewInBubble

/// Мини-цитата внутри бабла: показывает текст/тип родительского сообщения.
struct ReplyPreviewInBubble: View {
    let repliedMessage: Message
    let senderName: String
    let isCurrentUser: Bool
    
    var body: some View {
        HStack(spacing: 6) {
            // Вертикальная accent-полоска
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accentBarColor)
                .frame(width: 3)
            
            // Thumbnail фото (если ответ на изображение)
            if let thumbInfo = replyImageThumbInfo {
                CachedImageView(
                    thumbURL: thumbInfo.url,
                    fullImageURL: thumbInfo.url,
                    blurHash: nil,
                    imageWidth: thumbInfo.width,
                    imageHeight: thumbInfo.height,
                    targetSize: CGSize(width: 36, height: 36)
                )
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 36, maxHeight: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            
            VStack(alignment: .leading, spacing: 1) {
                Text(senderName)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(accentBarColor)
                
                Text(previewText)
                    .font(.caption2)
                    .foregroundStyle(isCurrentUser ? .white.opacity(0.8) : .secondary)
                    .lineLimit(2...3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
    
    private var accentBarColor: Color {
        isCurrentUser ? .white.opacity(0.7) : .blue
    }
    
    /// URL + размеры thumbnail для ответа на изображение
    private var replyImageThumbInfo: (url: URL, width: Double?, height: Double?)? {
        switch repliedMessage.content {
        case .image(_, let thumbURL, _, let width, let height, _):
            guard let url = thumbURL else { return nil }
            return (url, width, height)
        default:
            return nil
        }
    }
    
    private var previewText: String {
        switch repliedMessage.content {
        case .text(let text):
            return text
        case .image(_, _, let text, _, _, _):
            return text ?? "📷 Фото"
        }
    }
}

// MARK: - DateSeparatorView

/// Разделитель по дате: «Сегодня», «Вчера», «19 марта 2026»
struct DateSeparatorView: View {
    let date: Date
    
    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()
    
    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Сегодня"
        } else if calendar.isDateInYesterday(date) {
            return "Вчера"
        } else {
            return Self.fullDateFormatter.string(from: date)
        }
    }
    
    var body: some View {
        HStack {
            Spacer()
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color(.systemGray6))
                )
            Spacer()
        }
        .padding(.vertical, 8)
    }
}
