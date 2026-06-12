//
//  RootView.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 10.03.2026.
//


import SwiftUI

struct RootView: View {
    
    @State private var router = AppRouter()
    @AppStorage("didAcceptEULA") private var didAcceptEULA: Bool = false
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        Group {
            switch router.state {
            case .loading:
                VStack {
                    Image(systemName: "message.fill")
                        .font(.system(size: 80))
                        .foregroundColor(Color(.systemBlue))
                    ProgressView()
                        .padding(.top, 20)
                }
                .onAppear {
                    router.listenForAuthChanges()
                }
            case .auth:
                AuthView()
            case .main:
                ContentView()
            }
        }
        .environment(router)
        // EULA-гейт для пользователей, вошедших ДО появления требования принять условия
        // (App Store Guideline 1.2). Новые пользователи принимают EULA при регистрации (AuthView).
        .fullScreenCover(isPresented: Binding(
            get: { router.state == .main && !didAcceptEULA },
            set: { _ in }
        )) {
            EULAAcceptanceView()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                print("СЕРВЕР: Корень поймал пробуждение! Даем сигнал всем экранам!")
                router.appWakeUpTrigger += 1
                print("DIAG appWakeUpTrigger -> \(router.appWakeUpTrigger) phase=.active t=\(Date().timeIntervalSince1970)")
            }
        }
    }
}



