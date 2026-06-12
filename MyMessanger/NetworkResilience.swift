//
//  NetworkResilience.swift
//  MyMessanger
//
//  Общие помощники сетевой устойчивости (таймаут задаётся на URLSession в
//  SupabaseManager.makeHTTPSession; здесь — классификация транзиентных ошибок
//  для авто-retry в загрузке чатов/сообщений).
//

import Foundation

extension Error {
    /// Транзиентный сетевой сбой, на котором имеет смысл повторить запрос.
    /// -1005 (потеря соединения) типичен для первого запроса по «мёртвому» сокету;
    /// -1001 прилетает от нашего URLSession при зависании запроса (см.
    /// SupabaseManager.makeHTTPSession). Повтор по свежему соединению обычно проходит.
    /// На блокировку РКН/ТСПУ retry НЕ помогает (её снимает только VPN/реверс-прокси),
    /// но и вреда не наносит — после исчерпания попыток управление идёт дальше.
    var isTransientNetwork: Bool {
        let ns = self as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorNetworkConnectionLost,   // -1005
             NSURLErrorTimedOut,                 // -1001
             NSURLErrorCannotConnectToHost,      // -1004
             NSURLErrorCannotFindHost,           // -1003
             NSURLErrorNotConnectedToInternet:   // -1009
            return true
        default:
            return false
        }
    }
}
