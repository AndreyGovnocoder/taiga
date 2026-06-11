//
//  EULAAcceptanceView.swift
//  MyMessanger
//
//  Экран принятия условий использования для пользователей, вошедших ДО появления
//  EULA-гейта (показывается из RootView через fullScreenCover). При согласии выставляет
//  @AppStorage("didAcceptEULA") = true — тот же ключ, что и в форме регистрации (AuthView).
//

import SwiftUI

struct EULAAcceptanceView: View {
    @AppStorage("didAcceptEULA") private var didAcceptEULA: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    Text(LegalTexts.termsOfUse)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }

                VStack(spacing: 12) {
                    Text("Чтобы продолжить пользоваться Taiga, примите условия использования.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Button {
                        didAcceptEULA = true
                    } label: {
                        Text("Принять и продолжить")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(12)
                            .foregroundColor(.white)
                    }
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Условия использования")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(true)
        }
    }
}
