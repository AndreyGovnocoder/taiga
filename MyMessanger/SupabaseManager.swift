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
        }
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
