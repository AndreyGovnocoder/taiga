//
//  SupabaseAuthService.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 10.03.2026.
//

import Foundation
import Supabase

class SupabaseAuthService: AuthServiceProtocol {
    
    var currentUser: User? = nil
    private let client = SupabaseManager.shared.client
    
    init() {
        Task {
            do {
                let session = try await client.auth.session
                let userId = session.user.id.uuidString.lowercased()
                
                SupabaseManager.shared.setCurrentUserId(userId)
                
                await fetchUserData(userId: userId)
            } catch {
                
            }
        }
    }
    
    private func fetchUserData(userId: String) async {
        do {
            let userDTO: UserDTO = try await client
                .from("users")
                .select()
                .eq("id", value: userId)
                .single()
                .execute()
                .value
                
            await MainActor.run {
                self.currentUser = User(
                    id: userId,
                    phoneNumber: userDTO.phone_number ?? "",
                    name: userDTO.name,
                    nickname: userDTO.nickname ?? "user",
                    avatar: SupabaseConfig.rewrittenURL(fromStored: userDTO.avatar_url),
                    // Обход РКН: полный аватар тоже через текущий прокси-хост.
                    avatarFull: SupabaseConfig.rewrittenURL(fromStored: userDTO.avatar_url_full),
                    isOnline: userDTO.is_online
                )
            }
            Log.debug(.auth, "Профиль пользователя успешно загружен")
        } catch {
            Log.error(.auth, "СЕРВЕР: Ошибка загрузки данных профиля: \(error.localizedDescription)")
        }
    }
    
    func requestSMS(phoneNumber: String) async throws {
        throw NSError(domain: "NotImplemented", code: 0, userInfo:[NSLocalizedDescriptionKey: "Авторизация по SMS пока не доступна"])
    }
    
    func verifyCode(code: String) async throws -> User {
        throw NSError(domain: "NotImplemented", code: 0, userInfo:[NSLocalizedDescriptionKey: "Авторизация по SMS пока не доступна"])
    }
    
    func loginWithEmail(email: String, password: String) async throws -> User {
        let session = try await client.auth.signIn(email: email, password: password)
        
        let userId = session.user.id.uuidString.lowercased()
        SupabaseManager.shared.setCurrentUserId(userId)
        
        await fetchUserData(userId: userId)
        
        if let user = self.currentUser {
            return user
        } else {
            throw NSError(domain: "AuthError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Не удалось загрузить данные профиля"])
        }
    }
    
    func checkUserExists(phoneNumber: String) async throws -> Bool {
        let exists: Bool = try await client
            .rpc("check_phone_exists", params: ["p_phone": phoneNumber])
            .execute()
            .value
        return exists
    }
    
    func checkNicknameExists(nickname: String) async throws -> Bool {
        let exists: Bool = try await client
            .rpc("check_nickname_exists", params: ["p_nickname": nickname])
            .execute()
            .value
        return exists
    }
    
    func registerWithEmail(email: String, password: String, name: String, nickname: String, phoneNumber: String) async throws -> User {
        let exists = try await checkUserExists(phoneNumber: phoneNumber)
        if exists {
            throw NSError(domain: "AuthError", code: 400, userInfo: [NSLocalizedDescriptionKey: "Номер телефона уже зарегистрирован"])
        }
        
        let authResponse = try await client.auth.signUp(
            email: email,
            password: password,
            data: [
                "name": .string(name),
                "nickname": .string(nickname),
                "phone_number": .string(phoneNumber)
            ])
        
        let userId = authResponse.user.id.uuidString.lowercased()
        SupabaseManager.shared.setCurrentUserId(userId)
        
        let newUser = User(id: userId, phoneNumber: phoneNumber, name: name, nickname: nickname, isOnline: true)
        
        await MainActor.run {
            self.currentUser = newUser
        }
        
        return newUser
    }
    
    func deleteAccount() async throws {
        // Сервер — первым: аккаунт должен реально удалиться, прежде чем трогаем локальные данные.
        // Если RPC упадёт — бросаем ошибку и НИЧЕГО локально не теряем (состояние восстановимо).
        try await client.rpc("delete_user_account").execute()
        // Аккаунт уже удалён на сервере. Ошибка выхода из сессии не должна выглядеть как «ошибка удаления».
        try? await logout()
        SupabaseManager.shared.setCurrentUserId(nil)
        currentUser = nil
    }
    
    func updateProfile(name: String, nickname: String, avatarData: Data?) async throws -> User {
        guard let userId = SupabaseManager.shared.currentUserId else {
            throw NSError(domain: "AuthError", code: 401, userInfo: [NSLocalizedDescriptionKey: "Не авторизован"])
        }
        
        var updatedThumbUrl: String? = nil
        var updatedFullUrl: String? = nil

        if let fullData = avatarData {
            // avatarData приходит уже как «полная» версия (≤1280px, см. SettingsView).
            // Грузим ДВЕ версии: тумбу (≤256px — список/шапка, малый трафик) и полную
            // (профиль/fullscreen, высокое качество).
            let base = "\(userId)_\(UUID().uuidString.lowercased())"
            let thumbData = await ImageCompressor.shared.generateThumbnailData(from: fullData, maxPixelSize: 256) ?? fullData

            // Тумба всегда JPEG (generateThumbnailData). Полная может быть HEIC (resizeIfNeeded) —
            // имя/Content-Type ветвим по реальным байтам (как у медиа в чате), иначе объект «врёт»
            // формат (ломает ShareLink/веб/CDN-трансформы; для in-app декода по байтам не критично).
            let fullIsHEIC = fullData.isHEIC
            let thumbName = "\(base).jpg"
            let fullName = fullIsHEIC ? "\(base)_full.heic" : "\(base)_full.jpg"

            try await client.storage.from("avatars")
                .upload(thumbName, data: thumbData, options: FileOptions(contentType: "image/jpeg"))
            do {
                try await client.storage.from("avatars")
                    .upload(fullName, data: fullData, options: FileOptions(contentType: fullIsHEIC ? "image/heic" : "image/jpeg"))
            } catch {
                // Полная не залилась — убираем осиротевшую тумбу (не копим мусор) и пробрасываем.
                _ = try? await client.storage.from("avatars").remove(paths: [thumbName])
                throw error
            }

            updatedThumbUrl = try client.storage.from("avatars").getPublicURL(path: thumbName).absoluteString
            updatedFullUrl = try client.storage.from("avatars").getPublicURL(path: fullName).absoluteString
        }

        var updateDict: [String: AnyJSON] = [
            "name": .string(name),
            "nickname": .string(nickname)
        ]
        if let url = updatedThumbUrl {
            updateDict["avatar_url"] = .string(url)
        }
        if let urlFull = updatedFullUrl {
            updateDict["avatar_url_full"] = .string(urlFull)
        }

        try await client.from("users")
            .update(updateDict)
            .eq("id", value: userId)
            .execute()
        
        await fetchUserData(userId: userId)
        
        if let user = self.currentUser {
            return user
        } else {
            throw NSError(domain: "AuthError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Ошибка обновы профиля"])
        }
    }

    func logout() async throws {
        try await client.auth.signOut()
        SupabaseManager.shared.setCurrentUserId(nil)
        self.currentUser = nil
    }
}




