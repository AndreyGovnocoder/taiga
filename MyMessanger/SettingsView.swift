//
//  SettingsView.swift
//  MyMessanger
//

import SwiftUI
import PhotosUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppRouter.self) private var router
    
    @State private var avatarItem: PhotosPickerItem? = nil
    @State private var avatarData: Data? = nil
    @State private var currentAvatarURL: URL? = nil
    @State private var isCompressing: Bool = false
    @State private var isSaving: Bool = false
    @State private var errorMessage: String? = nil
    
    @State private var userName: String = ""
    @State private var userNickname: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Аватар
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            PhotosPicker(selection: $avatarItem, matching: .images, photoLibrary: .shared()) {
                                if let avatarData, let uiImage = UIImage(data: avatarData) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 100, height: 100)
                                        .clipShape(Circle())
                                } else if let currentAvatarURL {
                                    CachedImageView(
                                        thumbURL: currentAvatarURL,
                                        fullImageURL: nil,
                                        blurHash: nil,
                                        imageWidth: 100,
                                        imageHeight: 100,
                                        targetSize: CGSize(width: 100, height: 100)
                                    )
                                    .frame(width: 100, height: 100)
                                    .clipShape(Circle())
                                } else {
                                    Image(systemName: "person.circle.fill")
                                        .resizable()
                                        .foregroundStyle(.gray)
                                        .frame(width: 100, height: 100)
                                }
                            }
                            
                            if isCompressing {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Text("Изменить фото")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            }
                            
                            if !userName.isEmpty {
                                Text(userName)
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                
                                if !userNickname.isEmpty {
                                    Text("@\(userNickname)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                
                // MARK: - Разделы настроек
                Section {
                    NavigationLink {
                        AccountSettingsView()
                    } label: {
                        Label {
                            Text("Аккаунт")
                        } icon: {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.blue)
                        }
                    }
                    
                    NavigationLink {
                        ChatsSettingsView()
                    } label: {
                        Label {
                            Text("Чаты")
                        } icon: {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .foregroundStyle(.green)
                        }
                    }
                    
                    NavigationLink {
                        StorageSettingsView()
                    } label: {
                        Label {
                            Text("Хранилище и данные")
                        } icon: {
                            Image(systemName: "internaldrive")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label {
                            Text("О приложении")
                        } icon: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.gray)
                        }
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Назад") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView()
                    } else if avatarData != nil {
                        Button("Сохранить") {
                            saveAvatar()
                        }
                        .disabled(isCompressing)
                    }
                }
            }
            .alert("Ошибка", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("ОК") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                loadCurrentUserData()
            }
            .onChange(of: avatarItem) { _, newItem in
                Task {
                    isCompressing = true
                    if let data = try? await newItem?.loadTransferable(type: Data.self) {
                        avatarData = await ImageCompressor.shared.generateThumbnailData(from: data, maxPixelSize: 600) ?? data
                    }
                    isCompressing = false
                }
            }
        }
    }
    
    private func loadCurrentUserData() {
        if let user = router.authService.currentUser {
            self.userName = user.name
            self.userNickname = user.nickname
            self.currentAvatarURL = user.avatar
        }
    }
    
    private func saveAvatar() {
        guard let avatarData else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                if let user = router.authService.currentUser {
                    _ = try await router.authService.updateProfile(
                        name: user.name,
                        nickname: user.nickname,
                        avatarData: avatarData
                    )
                }
                await MainActor.run {
                    isSaving = false
                    self.avatarData = nil
                    loadCurrentUserData()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
