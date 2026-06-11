//
//  NetworkMonitor.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 24.03.2026.
//

import Foundation
import Network

extension Notification.Name {
    static let networkRestored = Notification.Name("networkRestored")
    /// Статус сообщения изменился (sent/failed после фоновой отправки). object = chatId: String
    static let messageStatusChanged = Notification.Name("messageStatusChanged")
}

/// Монитор сетевого подключения.
/// При переходе offline → online отправляет `.networkRestored` нотификацию
/// для автоматического retry недоставленных сообщений.
@Observable
final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()
    
    private(set) var isConnected: Bool = true
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor", qos: .utility)
    private var wasConnected: Bool = true
    
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            
            DispatchQueue.main.async {
                let previouslyConnected = self.isConnected
                self.isConnected = connected
                
                // Переход offline → online → notify для retry
                if connected && !previouslyConnected {
                    NotificationCenter.default.post(name: .networkRestored, object: nil)
                }
            }
        }
        monitor.start(queue: queue)
    }
    
    deinit {
        monitor.cancel()
    }
}
