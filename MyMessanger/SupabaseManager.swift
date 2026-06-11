//
//  SupabaseManager.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 10.03.2026.
//

import Foundation
import Supabase

final class SupabaseManager: @unchecked Sendable {
    static let shared = SupabaseManager()
    
    // URL и anon-ключ вынесены в SupabaseConfig (обход блокировок РКН — см. analysis-reports/).
    // По умолчанию хост = прямой адрес проекта, поэтому поведение идентично прежнему,
    // пока в SupabaseConfig.hostCandidates не добавлен прокси-домен.
    let client = SupabaseClient(
        supabaseURL: SupabaseConfig.currentURL,
        supabaseKey: SupabaseConfig.anonKey,
        options: SupabaseClientOptions(
            auth: SupabaseClientOptions.AuthOptions(
                emitLocalSessionAsInitialSession: true
            )
        )
    )
    
    // MARK: - Единый source of truth для ID текущего пользователя
    
    private static let userIdKey = "currentUserId"
    
    var currentUserId: String? {
        UserDefaults.standard.string(forKey: Self.userIdKey)
    }
    
    func setCurrentUserId(_ userId: String?) {
        if let userId {
            UserDefaults.standard.set(userId, forKey: Self.userIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.userIdKey)
            // При логауте сбрасываем кэш блокировок, чтобы следующий пользователь
            // на этом устройстве не унаследовал чужой набор (его пересоберёт fetchBlockedUsers).
            UserDefaults.standard.removeObject(forKey: Self.blockedKey)
            // EULA-согласие тоже per-account: следующий пользователь на устройстве должен
            // принять условия сам (App Store Guideline 1.2). Симметрично blockedKey.
            UserDefaults.standard.removeObject(forKey: "didAcceptEULA")
        }
    }

    // MARK: - Единый source of truth для заблокированных пользователей (UGC-модерация)

    private static let blockedKey = "blockedUserIds"

    /// Множество id заблокированных пользователей (lowercase UUID). Персистится в UserDefaults,
    /// чтобы фильтрация работала уже при мгновенном локальном рендере и переживала перезапуск.
    /// Авторитетный источник — сервер (fetchBlockedUsers); block/unblock обновляют набор сразу.
    var blockedUserIds: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.blockedKey) ?? [])
    }

    func setBlockedUserIds(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: Self.blockedKey)
    }

    func addBlockedUserId(_ id: String) {
        var ids = blockedUserIds
        ids.insert(id.lowercased())
        setBlockedUserIds(ids)
    }

    func removeBlockedUserId(_ id: String) {
        var ids = blockedUserIds
        ids.remove(id.lowercased())
        setBlockedUserIds(ids)
    }

    private init() {}
}

extension SupabaseManager {
    func saveApnsToken(_ token: String) async {
        guard let userId = currentUserId,
              let userUUID = UUID(uuidString: userId) else { return }
        
        do {
            try await client
                .from("users")
                .update(["apns_token": token])
                .eq("id", value: userUUID)
                .execute()
            print("СЕРВЕР: APNs токен успешно привязан к профилю")
        } catch {
            print("СЕРВЕР: Ошибка привязки токен: \(error.localizedDescription)")
        }
    }
}
