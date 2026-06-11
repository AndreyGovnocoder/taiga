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

    private var privacyPolicyText: String {
        """
        Политика конфиденциальности Taiga Messenger

        Последнее обновление: \(formattedDate)

        1. Сбор данных
        Мы собираем минимально необходимый объём данных для работы мессенджера: номер телефона, имя, никнейм и аватар.

        2. Хранение сообщений
        Сообщения хранятся локально на вашем устройстве. На сервере сообщения хранятся временно (до 3 дней) для доставки собеседнику.

        3. Шифрование
        Соединение с сервером защищено протоколом TLS. Данные передаются по зашифрованному каналу.

        4. Передача данных третьим лицам
        Мы не передаём ваши персональные данные третьим лицам.

        5. Удаление данных
        Вы можете удалить свой аккаунт и все связанные данные в настройках приложения.
        """
    }

    private var termsOfUseText: String {
        """
        Условия использования Taiga Messenger

        Последнее обновление: \(formattedDate)

        1. Общие положения
        Используя Taiga Messenger, вы соглашаетесь с настоящими условиями.

        2. Использование сервиса
        Запрещено использовать мессенджер для рассылки спама, угроз, незаконного контента.

        3. Аккаунт
        Вы несёте ответственность за безопасность своего аккаунта и все действия, совершённые от его имени.

        4. Ограничение ответственности
        Мессенджер предоставляется «как есть». Мы не гарантируем бесперебойную работу сервиса.

        5. Изменения условий
        Мы оставляем за собой право изменять настоящие условия. Актуальная версия доступна в приложении.
        """
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        return formatter.string(from: Date())
    }
}
