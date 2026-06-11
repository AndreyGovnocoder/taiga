//
//  AboutView.swift
//  MyMessanger
//

import SwiftUI

struct AboutView: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    
    var body: some View {
        List {
            // MARK: - Иконка и название
            Section {
                VStack(spacing: 16) {
                    if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
                       let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
                       let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
                       let lastIcon = iconFiles.last,
                       let icon = UIImage(named: lastIcon) {
                        Image(uiImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    } else {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                            .foregroundStyle(.blue.gradient)
                    }
                    
                    Text("Taiga Messenger")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("Версия \(appVersion) (\(buildNumber))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            
            // MARK: - Разработка
            Section("Разработка") {
                HStack {
                    Label("Разработчик", systemImage: "person.fill")
                    Spacer()
                    Text("Андрей Гулий")
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Label("Платформа", systemImage: "iphone")
                    Spacer()
                    Text("iOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)")
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Label("Фреймворк", systemImage: "swift")
                    Spacer()
                    Text("SwiftUI + SwiftData")
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Label("Бэкенд", systemImage: "cloud")
                    Spacer()
                    Text("Supabase")
                        .foregroundStyle(.secondary)
                }
            }
            
            // MARK: - Правовая информация
            Section("Правовая информация") {
                NavigationLink {
                    ScrollView {
                        Text(privacyPolicyText)
                            .padding()
                    }
                    .navigationTitle("Политика конфиденциальности")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Политика конфиденциальности", systemImage: "hand.raised")
                }
                
                NavigationLink {
                    ScrollView {
                        Text(termsOfUseText)
                            .padding()
                    }
                    .navigationTitle("Условия использования")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Условия использования", systemImage: "doc.text")
                }
            }
            
            // MARK: - Копирайт
            Section {
                Text("© \(Calendar.current.component(.year, from: Date())) Taiga Messenger.\nВсе права защищены.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .navigationTitle("О приложении")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - Заглушки текстов

    // Юридические тексты вынесены в единый источник LegalTexts (раздел про UGC обязателен
    // для App Store и должен совпадать с EULA-гейтом регистрации).
    private var privacyPolicyText: String { LegalTexts.privacyPolicy }

    private var termsOfUseText: String { LegalTexts.termsOfUse }
}
