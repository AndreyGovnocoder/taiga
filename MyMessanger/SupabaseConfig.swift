//
//  SupabaseConfig.swift
//  MyMessanger
//
//  Конфигурация подключения к Supabase и выбор рабочего хоста.
//  Вынесено из хардкода в SupabaseManager для поддержки обхода блокировок РКН
//  (реверс-прокси на своём домене). См. analysis-reports/02-roadmap-to-release.md (Этап 1)
//  и analysis-reports/03-action-guide.md (шаги 4–7).
//
//  Основной хост — реверс-прокси i-goose.pro (AEZA/Caddy, обход РКН); прямой адрес Supabase — fallback.
//

import Foundation

enum SupabaseConfig {

    /// Публикуемый (anon) ключ Supabase. По дизайну Supabase он публичный
    /// (предназначен для клиента); защита данных обеспечивается серверным RLS, а не секретностью ключа.
    nonisolated static let anonKey = "sb_publishable_XKl70ux3zYBIiodYYowweQ_0ERHg6T1"

    /// Прямой адрес проекта Supabase. На мобильных операторах РФ может быть недоступен
    /// (проект на AWS за Cloudflare попадает под блокировки/троттлинг ТСПУ).
    nonisolated static let directHost = "rhoyopwzdqtcyawiipya.supabase.co"

    /// Упорядоченный список хостов-кандидатов; перебирается сверху вниз при недоступности.
    ///
    /// После поднятия реверс-прокси (analysis-reports/03-action-guide.md, шаги 4–7) добавить:
    ///   - ПЕРВЫМ  — основной прокси-домен  ("api.<ваш-домен>")
    ///   - ВТОРЫМ  — резервный прокси-домен на ДРУГОМ хостере/в другой стране
    /// Прямой адрес оставить ПОСЛЕДНИМ: в РФ на мобильном он не сработает, но полезен на Wi-Fi и вне РФ.
    ///
    /// Список зашит в бинарь специально: смена точки входа НЕ должна требовать релиза в App Store.
    nonisolated static let hostCandidates: [String] = [
        "i-goose.pro",            // ← основной реверс-прокси (AEZA/Caddy, обход РКН)
        // "api.ВАШ-РЕЗЕРВНЫЙ-ДОМЕН",  // ← резервный прокси (другой хостер/страна)
        directHost,                    // прямой адрес (fallback)
    ]

    /// Хост проекта для upstream-маршрутизации (Host/SNI). НЕ меняется при проксировании —
    /// прокси обязан переписывать заголовок Host и SNI на это значение (см. Caddyfile в инструкции),
    /// иначе Realtime упадёт с tenant_not_found_in_host.
    nonisolated static let projectHostForUpstream = directHost

    // MARK: - Выбранный хост (переживает перезапуск)

    nonisolated private static let chosenHostKey = "supabaseChosenHost"

    /// Текущий выбранный хост. По умолчанию — первый кандидат.
    /// Сохранённое значение игнорируется, если его больше нет в списке кандидатов
    /// (например, после удаления прокси-домена из конфига).
    nonisolated static var chosenHost: String {
        get {
            if let saved = UserDefaults.standard.string(forKey: chosenHostKey),
               hostCandidates.contains(saved) {
                return saved
            }
            return hostCandidates.first ?? directHost
        }
        set { UserDefaults.standard.set(newValue, forKey: chosenHostKey) }
    }

    /// URL для произвольного хоста из конфига (строка всегда валидна — источник контролируемый).
    static func url(forHost host: String) -> URL {
        URL(string: "https://\(host)")!
    }

    /// Текущий базовый URL для инициализации SupabaseClient.
    static var currentURL: URL { url(forHost: chosenHost) }

    // MARK: - Переписывание абсолютных медиа-URL на текущий хост

    /// «Наши» хосты, чьи абсолютные URL нужно вести через текущий выбранный хост.
    nonisolated private static var knownOwnHosts: Set<String> { Set((hostCandidates + [directHost]).map { $0.lowercased() }) }

    /// Переписывает host у абсолютного Supabase-URL (storage/медиа/аватары) на текущий `chosenHost`.
    /// Зачем: медиа-URL хранятся в БД абсолютными (getPublicURL().absoluteString) — старые записи
    /// содержат прямой хост Supabase, заблокированный в РФ. Эта функция ведёт старые и будущие
    /// ссылки через прокси и делает их устойчивыми к смене VPS. Чужие URL не трогает; Caddy
    /// проксирует путь как есть — меняется только host.
    nonisolated static func rewrittenToCurrentHost(_ url: URL) -> URL {
        guard let rawHost = url.host else { return url }
        let host = rawHost.lowercased()
        guard host != chosenHost.lowercased(), knownOwnHosts.contains(host) else { return url }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.host = chosenHost
        return comps.url ?? url
    }

    /// Обёртка для строкового URL-поля из БД (avatar_url / image_url). nil — если строка пустая/битая.
    nonisolated static func rewrittenURL(fromStored string: String?) -> URL? {
        guard let string = string, let url = URL(string: string) else { return nil }
        return rewrittenToCurrentHost(url)
    }
}

// MARK: - Проверка доступности хостов (основа failover)

extension SupabaseConfig {

    /// Перебирает кандидатов по порядку и возвращает первый, чей `/auth/v1/health` отвечает 200.
    /// Не трогает живой SupabaseClient — только выбирает хост. nil — если ни один не ответил.
    ///
    /// ВНИМАНИЕ: `/auth/v1/health` проверяет только HTTPS-плечо. Realtime (WSS) может резаться
    /// ТСПУ отдельно — для полноценного failover нужна также проба WebSocket. Это будет добавлено
    /// вместе с горячей сменой клиента и переподпиской realtime (отдельный инкремент, проверка на Mac).
    static func firstReachableHost(timeout: TimeInterval = 4) async -> String? {
        for host in hostCandidates {
            if await isHealthy(host: host, timeout: timeout) {
                return host
            }
        }
        return nil
    }

    static func isHealthy(host: String, timeout: TimeInterval = 4) async -> Bool {
        var request = URLRequest(url: url(forHost: host).appendingPathComponent("auth/v1/health"))
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
