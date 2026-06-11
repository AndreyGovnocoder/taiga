//
//  AppRouter.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 10.03.2026.
//

import SwiftUI
import Supabase

enum AppState {
    case loading
    case auth
    case main
}

@Observable
class AppRouter {
    var state: AppState = .loading
    
    let authService: AuthServiceProtocol
    
    var appWakeUpTrigger: Int = 0
    
    init(authService: AuthServiceProtocol = SupabaseAuthService()) {
        self.authService = authService
    }
    
    /// Подписывается на события авторизации Supabase.
    /// Реагирует мгновенно, без race condition с таймером.
    @MainActor
    func listenForAuthChanges() {
        Task {
            for await (event, session) in SupabaseManager.shared.client.auth.authStateChanges {
                switch event {
                case .initialSession:
                    // Первое событие — Supabase загрузил сессию из кэша
                    if let session {
                        let userId = session.user.id.uuidString.lowercased()
                        SupabaseManager.shared.setCurrentUserId(userId)
                        self.state = .main
                    } else {
                        self.state = .auth
                    }
                    
                case .signedIn:
                    if let session {
                        SupabaseManager.shared.setCurrentUserId(session.user.id.uuidString.lowercased())
                    }
                    self.state = .main
                    
                case .signedOut:
                    SupabaseManager.shared.setCurrentUserId(nil)
                    self.state = .auth
                    
                default:
                    break
                }
            }
        }
    }
}
