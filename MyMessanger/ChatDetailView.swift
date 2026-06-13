//
//  ChatDetailView.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 14.03.2026.
//

import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import MessagingUI

// MARK: - ChatDetailView

@MainActor
struct ChatDetailView: View {
    let chat: Chat
    
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    
    @State private var viewModel: ChatViewModel
    @State private var scrollPosition: TiledScrollPosition
    @State private var scrollGeometry: TiledScrollGeometry?
    @State private var activeThreadRootId: String? = nil
    @State private var activeThreadVM: ThreadViewModel? = nil
    @State private var threadAutoFocusInput: Bool = false
    @State private var swipedMessageId: String? = nil
    @State private var chatRevealed: Bool = false
    @FocusState private var isInputFocused: Bool
    
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var selectedPhotosItems: [PhotosPickerItem] = []
    @State private var selectedPhotos: [SelectedPhoto] = []
    @State private var cameraImagesData: [Data] = []  // Binding для CameraPicker
    @State private var captionText: String = ""
    @State private var fullscreenItem: FullscreenImageItem?
    
    // Editing message
    @State private var editingMessage: Message? = nil
    @State private var editText: String = ""
    
    // Selection mode
    @State private var sharedSelection = SharedSelectionState()
    
    private var isSelectionMode: Bool {
        get { sharedSelection.isSelectionMode }
        nonmutating set { sharedSelection.isSelectionMode = newValue }
    }
    private var selectedMessageIds: Set<String> {
        get { sharedSelection.selectedIds }
        nonmutating set { sharedSelection.selectedIds = newValue }
    }
    
    @State private var showDeleteError: Bool = false
    @State private var showGroupInfo: Bool = false
    @State private var showChatInfo: Bool = false
    @State private var showSavedToast: Bool = false

    // UGC-модерация (жалоба на отдельное сообщение из контекст-меню ячейки).
    // Жалоба/блокировка собеседника переехали на экран профиля (ChatInfoView).
    @State private var reportTargetMessage: Message?
    @State private var moderationNotice: String?

    init(chat: Chat) {
        self.chat = chat
        self._viewModel = State(initialValue: ChatViewModel(chat: chat))
        self._scrollPosition = State(initialValue: TiledScrollPosition(
            autoScrollsToBottomOnAppend: true,
            scrollsToBottomOnReplace: true
        ))
    }
    
    private var isNearBottom: Bool {
        guard let geometry = scrollGeometry else { return true }
        return geometry.pointsFromBottom < 100
    }

    /// Собеседник в личном (1:1) чате — для блокировки/жалобы из шапки.
    private var interlocutor: User? {
        guard !chat.isGroup else { return nil }
        let currentId = SupabaseManager.shared.currentUserId ?? ""
        return chat.participants.first(where: { $0.id != currentId })
    }
    
    // MARK: - Body
    
    var body: some View {
        mainContentStack
            .navigationTitle(isSelectionMode ? "Выбрано: \(selectedMessageIds.count)" : chat.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(fullscreenItem != nil ? .hidden : .visible, for: .navigationBar)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showGroupInfo) {
                GroupInfoView(chat: chat, onChatClosed: { dismiss() })
            }
            .sheet(isPresented: $showChatInfo) {
                ChatInfoView(
                    chat: chat,
                    interlocutor: interlocutor,
                    onChatCleared: { viewModel.refreshWindow() },
                    onChatClosed: { dismiss() }
                )
            }
            .confirmationDialog("Пожаловаться на сообщение?", isPresented: Binding(
                get: { reportTargetMessage != nil },
                set: { if !$0 { reportTargetMessage = nil } }
            ), titleVisibility: .visible) {
                Button("Пожаловаться", role: .destructive) {
                    if let msg = reportTargetMessage { reportMessage(msg) }
                }
                Button("Отмена", role: .cancel) { }
            } message: {
                Text("Жалоба будет отправлена на модерацию.")
            }
            .alert("Готово", isPresented: Binding(
                get: { moderationNotice != nil },
                set: { if !$0 { moderationNotice = nil } }
            )) {
                Button("ОК", role: .cancel) { }
            } message: {
                Text(moderationNotice ?? "")
            }
            .alert("Ошибка удаления", isPresented: $showDeleteError) {
                Button("ОК", role: .cancel) { }
            } message: {
                Text("Ошибка удаления, повторите позже")
            }
            .alert("Редактировать", isPresented: Binding(
                get: { editingMessage != nil },
                set: { if !$0 { editingMessage = nil } }
            )) {
                TextField("Текст сообщения", text: $editText)
                Button("Сохранить") {
                    if let msg = editingMessage, !editText.isEmpty {
                        Task {
                            await viewModel.editMessage(msg, newText: editText)
                        }
                    }
                    editingMessage = nil
                }
                Button("Отмена", role: .cancel) { editingMessage = nil }
            }
            .onAppear { handleOnAppear() }
            .onDisappear { handleOnDisappear() }
            .onChange(of: router.appWakeUpTrigger) { _, _ in
                Task { await viewModel.refreshAfterWakeUp() }
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
            .onChange(of: activeThreadRootId) { _, newRootId in
                handleThreadChange(newRootId)
            }
            .onReceive(NotificationCenter.default.publisher(for: .imageSavedToPhotos)) { _ in
                withAnimation { showSavedToast = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { showSavedToast = false }
                }
            }
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
                            .padding(.bottom, 100)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
    }
    
    // MARK: - Body Subviews
    
    private var mainContentStack: some View {
        ZStack {
            if viewModel.isInitialLoading {
                ProgressView("Загрузка сообщений...")
            } else {
                chatContent
                    .opacity(chatRevealed ? 1 : 0)
                    .animation(.easeOut(duration: 0.3), value: chatRevealed)
                    .allowsHitTesting(activeThreadRootId == nil)
            }
            
            threadOverlay
            fullscreenOverlay
        }
    }
    
    @ViewBuilder
    private var threadOverlay: some View {
        if let threadVM = activeThreadVM {
            ThreadOverlayView(
                viewModel: threadVM,
                autoFocusInput: threadAutoFocusInput,
                onDismiss: {
                    let shouldScroll = threadVM.didSendMessages
                    activeThreadRootId = nil
                    activeThreadVM = nil
                    viewModel.refreshAfterThreadDismiss()
                    if shouldScroll {
                        scrollPosition.scrollTo(edge: .bottom, animated: true)
                    }
                },
                onTapImage: { imageURL, thumbURL, blurHash, width, height in
                    fullscreenItem = FullscreenImageItem(
                        imageURL: imageURL,
                        thumbURL: thumbURL,
                        blurHash: blurHash,
                        imageWidth: width,
                        imageHeight: height
                    )
                }
            )
            .transition(.opacity)
        }
    }
    
    @ViewBuilder
    private var fullscreenOverlay: some View {
        if let item = fullscreenItem {
            FullscreenImageViewer(
                imageURL: item.imageURL,
                thumbURL: item.thumbURL,
                blurHash: item.blurHash,
                imageWidth: item.imageWidth,
                imageHeight: item.imageHeight,
                onDismiss: {
                    withAnimation(.easeOut(duration: 0.25)) {
                        fullscreenItem = nil
                    }
                }
            )
            .transition(.opacity)
            .ignoresSafeArea()
        }
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !isSelectionMode {
            ToolbarItem(placement: .principal) {
                principalToolbarLabel
            }
        }
        // Жалоба/блокировка собеседника переехали из меню «…» на экран профиля чата
        // (тап по аватарке/имени в шапке → ChatInfoView). Для групп — GroupInfoView.
        if isSelectionMode {
            ToolbarItem(placement: .topBarLeading) {
                Button("Отмена") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSelectionMode = false
                        selectedMessageIds.removeAll()
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var principalToolbarLabel: some View {
        if chat.isGroup {
            Button {
                showGroupInfo = true
            } label: {
                HStack(spacing: 8) {
                    groupChatAvatar
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chat.displayTitle)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("\(chat.participants.count) участников")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Button {
                showChatInfo = true
            } label: {
                HStack(spacing: 8) {
                    personalChatAvatar
                    Text(chat.displayTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
            }
        }
    }
    
    @ViewBuilder
    private var groupChatAvatar: some View {
        let groupAvatarURL: URL? = {
            if case .group(_, let url) = chat.type { return url }
            return nil
        }()
        if let avatarURL = groupAvatarURL {
            CachedImageView(avatarURL: avatarURL, size: 28)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.purple.opacity(0.2))
                .frame(width: 28, height: 28)
                .overlay(
                    Text(String(chat.displayTitle.prefix(1)))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.purple)
                )
        }
    }
    
    @ViewBuilder
    private var personalChatAvatar: some View {
        let currentId = SupabaseManager.shared.currentUserId ?? ""
        let avatar = chat.participants.first(where: { $0.id != currentId })?.avatar
        if let avatar {
            CachedImageView(avatarURL: avatar, size: 28)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.blue.opacity(0.2))
                .frame(width: 28, height: 28)
                .overlay(
                    Text(String(chat.displayTitle.prefix(1)))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                )
        }
    }
    
    // MARK: - Lifecycle Handlers
    
    private func handleOnAppear() {
        // Открыт этот чат → подавляем foreground-пуш по нему (сообщение и так в ленте).
        SupabaseManager.shared.activeChatId = chat.id
        viewModel.setup(context: context)
        Task {
            await viewModel.loadInitial()
            try? await Task.sleep(for: .milliseconds(50))
            chatRevealed = true
            await viewModel.markAsRead()
        }
    }

    private func handleOnDisappear() {
        // Чат закрыт (pop/блокировка) — снова разрешаем баннеры по нему.
        SupabaseManager.shared.activeChatId = nil
        Task { await viewModel.markAsRead() }
    }
    
    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        if newPhase == .background || newPhase == .inactive {
            if viewModel.isNearBottom {
                Task { await viewModel.markAsRead() }
            }
        }
    }
    
    private func handleThreadChange(_ newRootId: String?) {
        if let rootId = newRootId {
            activeThreadVM = ThreadViewModel(
                rootMessageId: rootId,
                parentViewModel: viewModel,
                initialReplyToId: swipedMessageId
            )
            swipedMessageId = nil
        } else {
            activeThreadVM = nil
        }
    }
    
    // MARK: - Chat Content
    
    private var chatContent: some View {
        ZStack(alignment: .bottomTrailing) {
            tiledMessageList
            
            // Scroll to bottom FAB + badge непрочитанных
            if !isNearBottom {
                scrollToBottomButton
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomSafeAreaContent
        }
        .animation(.easeInOut(duration: 0.2), value: isNearBottom)
        .animation(.easeInOut(duration: 0.2), value: viewModel.newMessagesWhileScrolledUp)
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
            // Мгновенно добавляем placeholder'ы, параллельно загружаем лёгкие thumbnails
            let newPhotos = newItems.map { SelectedPhoto(pickerItem: $0) }
            selectedPhotos.append(contentsOf: newPhotos)
            selectedPhotosItems = []
            
            // Параллельная загрузка thumbnails (лёгкие, не full-size)
            for i in (selectedPhotos.count - newPhotos.count)..<selectedPhotos.count {
                guard let item = selectedPhotos[i].pickerItem else { continue }
                let index = i
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        // Генерируем лёгкий thumbnail (200px) для strip preview
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
            // Камера отдаёт Data мгновенно — конвертируем в SelectedPhoto
            for data in newData {
                let photo = SelectedPhoto(cameraData: data)
                selectedPhotos.append(photo)
            }
            cameraImagesData = []
        }
    }
    // MARK: - Input Bar
    
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Кнопка 📎 — меню вложений
            Button {
                showAttachMenu = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
            .padding(.bottom, 6)
            
            // Многострочное поле ввода (как в Telegram/WhatsApp)
            ZStack(alignment: .topLeading) {
                // Placeholder
                if inputTextBinding.wrappedValue.isEmpty {
                    Text(selectedPhotos.isEmpty ? "Сообщение" : "Подпись к фото...")
                        .foregroundStyle(.placeholder)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                
                TextEditor(text: inputTextBinding)
                    .focused($isInputFocused)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .frame(minHeight: 36, maxHeight: 120)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
            
            Button {
                handleSend()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(canSend ? .blue : .gray)
            }
            .disabled(!canSend)
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.bar)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
    
    private var inputTextBinding: Binding<String> {
        if selectedPhotos.isEmpty {
            return Binding(
                get: { viewModel.inputText },
                set: { viewModel.inputText = $0 }
            )
        } else {
            return $captionText
        }
    }
    
    private var canSend: Bool {
        if !selectedPhotos.isEmpty {
            // Можно отправить только когда все thumbnail загружены
            return selectedPhotos.allSatisfy { $0.thumbnail != nil }
        }
        return !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private func handleSend() {
        if !selectedPhotos.isEmpty {
            // Отправка изображений — загружаем полную Data при отправке
            let photos = selectedPhotos
            let caption = captionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : captionText
            selectedPhotos = []
            captionText = ""
            Task {
                // Загружаем полные Data параллельно
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
                    await viewModel.sendMediaMessages(datas: datas, caption: caption)
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
    
    // MARK: - Image Strip Preview
    
    @ViewBuilder
    private var imageStripPreview: some View {
        let strip = ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selectedPhotos) { photo in
                    imageStripThumbnail(photo: photo)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        strip
    }
    
    @ViewBuilder
    private func imageStripThumbnail(photo: SelectedPhoto) -> some View {
        ZStack(alignment: .topTrailing) {
            if let thumb = photo.thumbnail {
                thumb
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                // Placeholder пока thumbnail загружается
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
    
    /// Резолв имени отправителя из участников чата
    private func senderName(for message: Message) -> String {
        if message.isCurrentUser { return "Вы" }
        return chat.participants.first(where: { $0.id == message.senderId })?.name ?? "Собеседник"
    }
    
    // MARK: - Selection Mode
    
    private func toggleSelection(_ messageId: String) {
        if selectedMessageIds.contains(messageId) {
            selectedMessageIds.remove(messageId)
            if selectedMessageIds.isEmpty {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSelectionMode = false
                }
            }
        } else {
            selectedMessageIds.insert(messageId)
        }
    }
    
    @ViewBuilder
    private var selectionToolbar: some View {
        HStack(spacing: 0) {
            // Переслать (заглушка)
            Button {
                // TODO: реализовать пересылку выбранных сообщений
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.right")
                        .font(.title3)
                    Text("Переслать")
                        .font(.caption2)
                }
            }
            .disabled(selectedMessageIds.isEmpty)
            .frame(maxWidth: .infinity)
            
            // Копировать
            Button {
                viewModel.copyMessagesText(ids: selectedMessageIds)
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSelectionMode = false
                    selectedMessageIds.removeAll()
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                        .font(.title3)
                    Text("Копировать")
                        .font(.caption2)
                }
            }
            .disabled(selectedMessageIds.isEmpty)
            .frame(maxWidth: .infinity)
            
            // Поделиться
            ShareLink(items: [viewModel.shareMessagesText(ids: selectedMessageIds)]) {
                VStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                    Text("Поделиться")
                        .font(.caption2)
                }
            }
            .disabled(selectedMessageIds.isEmpty)
            .frame(maxWidth: .infinity)
            
            // Удалить (только свои)
            let hasOwnSelected = viewModel.hasOwnMessages(ids: selectedMessageIds)
            Button(role: .destructive) {
                Task {
                    let success = await viewModel.deleteSelectedMessages(ids: selectedMessageIds, state: sharedSelection)
                    if success {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSelectionMode = false
                            selectedMessageIds.removeAll()
                        }
                    } else {
                        showDeleteError = true
                    }
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.title3)
                    Text("Удалить")
                        .font(.caption2)
                }
            }
            .disabled(!hasOwnSelected)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.blue)
        .padding(.vertical, 10)
        .background(.bar)
    }
    
    // MARK: - Extracted Views for Compilation Speed
    
    private func messageCell(for chatItem: ChatItem) -> TaigaMessageCell {
        TaigaMessageCell(
            item: chatItem.message,
            showDateSeparator: chatItem.showDateSeparator,
            repliedMessage: chatItem.repliedMessage,
            repliedSenderName: chatItem.repliedSenderName,
            threadCount: chatItem.threadCount,
            senderName: chatItem.senderName,
            senderAvatar: chatItem.senderAvatar,
            isGroupChat: chatItem.isGroupChat,
            isFirstFromSender: chatItem.isFirstFromSender,
            isLastFromSender: chatItem.isLastFromSender,
            onOpenThread: { threadRootId in
                threadAutoFocusInput = false
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    activeThreadRootId = threadRootId
                }
            },
            onDelete: {
                Task {
                    await viewModel.deleteMessage(chatItem.message, state: sharedSelection)
                }
            },
            onReply: { message in
                let threadRoot = message.threadRootId ?? message.id
                swipedMessageId = message.id
                threadAutoFocusInput = true
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    activeThreadRootId = threadRoot
                }
            },
            onTapImage: { imageURL, thumbURL, blurHash, width, height in
                fullscreenItem = FullscreenImageItem(
                    imageURL: imageURL,
                    thumbURL: thumbURL,
                    blurHash: blurHash,
                    imageWidth: width,
                    imageHeight: height
                )
            },
            onRetry: {
                Task {
                    await viewModel.retryImageMessage(chatItem.message)
                }
            },
            onCopy: {
                viewModel.copyMessageText(chatItem.message)
            },
            onForward: {
                // TODO: реализовать пересылку
            },
            onReport: {
                reportTargetMessage = chatItem.message
            },
            onSelect: {
                if isSelectionMode {
                    toggleSelection(chatItem.message.id)
                } else {
                    let wasNearBottom = viewModel.isNearBottom
                    
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isInputFocused = false // Синхронно сбрасываем фокус
                        isSelectionMode = true
                        selectedMessageIds = [chatItem.message.id]
                        
                        // Плавный скролл к низу внутри той же анимации,
                        // чтобы компенсировать отъезд клавиатуры без скачка
                        if wasNearBottom {
                            scrollPosition.scrollTo(edge: .bottom, animated: true)
                        }
                    }
                }
            },
            onEdit: { message in
                editText = ""
                if case .text(let text) = message.content {
                    editText = text
                }
                editingMessage = message
            }
        )
    }
    
    // MARK: - Moderation Actions

    private func reportMessage(_ message: Message) {
        Task {
            do {
                try await viewModel.chatService.reportContent(message: message, reason: "Жалоба из чата")
                moderationNotice = "Жалоба отправлена. Спасибо."
            } catch {
                moderationNotice = "Не удалось отправить жалобу. Попробуйте позже."
            }
        }
    }

    private var tiledMessageList: some View {
        TiledView(
            dataSource: viewModel.dataSource,
            scrollPosition: $scrollPosition,
            makeInitialState: { _ in sharedSelection }
        ) { chatItem in
            messageCell(for: chatItem)
        }
        .prependLoader(.loader(perform: {
            await viewModel.loadOlder()
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
        .typingIndicator(.indicator(isVisible: viewModel.isTyping) {
            HStack(spacing: 8) {
                TypingDotsIndicator()
                Text("Печатает...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        })
        .onTiledScrollGeometryChange { geometry in
            scrollGeometry = geometry
            let nearBottom = isNearBottom
            scrollPosition.autoScrollsToBottomOnAppend = nearBottom
            viewModel.isNearBottom = nearBottom
            
            // Пользователь долистал до низа — сбрасываем badge
            if nearBottom && viewModel.newMessagesWhileScrolledUp > 0 {
                viewModel.resetNewMessagesBadge()
                Task { await viewModel.markAsRead() }
            }
        }
        .onTapBackground {
            isInputFocused = false
        }
        .onDragIntoBottomSafeArea {
            isInputFocused = false
        }
        .contentMargins(.bottom, 60, for: .scrollContent)
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 0)
        }
    }
    
    private var scrollToBottomButton: some View {
        Button {
            scrollPosition.scrollTo(edge: .bottom, animated: true)
            viewModel.resetNewMessagesBadge()
            Task { await viewModel.markAsRead() }
        } label: {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title)
                .foregroundStyle(.blue)
                .background(Circle().fill(.white))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                .overlay(alignment: .topTrailing) {
                    if viewModel.newMessagesWhileScrolledUp > 0 {
                        Text("\(viewModel.newMessagesWhileScrolledUp)")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Circle().fill(.red))
                            .offset(x: 6, y: -6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 8)
        .transition(.scale.combined(with: .opacity))
    }
    
    private var bottomSafeAreaContent: some View {
        VStack(spacing: 0) {
            if isSelectionMode {
                selectionToolbar
            } else {
                // Reply Preview Bar
                if viewModel.replyToMessage != nil {
                    ReplyPreviewBar(
                        message: viewModel.replyToMessage!,
                        senderName: senderName(for: viewModel.replyToMessage!),
                        onCancel: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                viewModel.cancelReply()
                            }
                        }
                    )
                }
                
                // Strip preview выбранных фото
                if !selectedPhotos.isEmpty {
                    imageStripPreview
                }
                
                inputBar
            }
        }
    }
}

// MARK: - Reply Preview Bar

/// Компактная панель предпросмотра ответа над input bar.
struct ReplyPreviewBar: View {
    let message: Message
    let senderName: String
    let onCancel: () -> Void
    
    var body: some View {
        HStack(spacing: 6) {
            // Accent bar
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.blue)
                .frame(width: 2, height: 20)
            
            // Имя + текст в одну строку
            Text(displaySenderName)
                .font(.body)
                .fontWeight(.bold)
                .foregroundStyle(.blue)
            
            Text(replyPreviewText)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            
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
        .padding(.vertical, 4)
        .background(.bar)
    }
    
    private var displaySenderName: String {
        senderName + ":"
    }
    
    private var replyPreviewText: String {
        switch message.content {
        case .text(let text):
            return text
        case .image(_, _, let text, _, _, _):
            return text ?? "📷 Фото"
        }
    }
}

// MARK: - Typing Dots Indicator

/// Анимированные три точки "печатает..." — замена TypingDotsView из MessagingUI
struct TypingDotsIndicator: View {
    @State private var animating = false
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .offset(y: animating ? -4 : 0)
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
