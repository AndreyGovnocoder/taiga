//
//  ContactsViewModel.swift
//  MyMessanger
//
//  Created by Гулий Андрей on 18.03.2026.
//


import SwiftUI
import Contacts
import SwiftData

@Observable
class ContactsViewModel {
    
    var registeredUsers: [User] = []
    var isLoading: Bool = false
    var errorMessage: String? = nil
    
    private let chatService: ChatServiceProtocol
    
    init(chatService: ChatServiceProtocol? = nil) {
        self.chatService = chatService ?? SupabaseChatService()
    }
    
    @MainActor
    func fetchContacts() async {
        isLoading = true
        errorMessage = nil
        //defer { isLoading = false }
        
        do {
            let store = CNContactStore()
            let granted = try await store.requestAccess(for: .contacts)
            guard granted else {
                errorMessage = "Для поиска друзей разрешите доступ к контактам в настройках"
                isLoading = false
                return
            }
            
            let rawPhoneNumbers = try await Task.detached(priority: .userInitiated) {
                let keys = [
                    CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor,
                    CNContactPhoneNumbersKey as CNKeyDescriptor
                ]
                
                let request = CNContactFetchRequest(keysToFetch: keys)
                var numbers = Set<String>()
                
                try store.enumerateContacts(with: request) { contact, _ in
                    for phoneVal in contact.phoneNumbers {
                        if let normalized = Self.normalizePhone(phoneVal.value.stringValue) {
                            numbers.insert(normalized)
                        }
                    }
                }
                
                return Array(numbers)
            }.value
            
            guard !rawPhoneNumbers.isEmpty else {
                errorMessage = "У вас нет контактов с номерами телефонов"
                isLoading = false
                return
            }
            
            let users = try await chatService.fetchRegisteredContacts(phoneNumbers: Array(rawPhoneNumbers))
            
            let currentUserId = SupabaseManager.shared.currentUserId ?? ""
            
            self.registeredUsers = users
                .filter { $0.id != currentUserId }
                .sorted { $0.name < $1.name }
        } catch {
            errorMessage = "Ошибка получения контактов: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    @MainActor
    func openChat(with targetUserId: String, context: ModelContext) async throws -> Chat {
        return try await chatService.createOrGetPersonalChat(with: targetUserId, context: context)
    }
    
    private static func normalizePhone(_ phone: String) -> String? {
        var digits = phone.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        guard !digits.isEmpty else { return nil }
        
        if digits.count == 11 && digits.hasPrefix("8") {
            digits.removeFirst()
            digits = "7" + digits
        } else if digits.count == 10 && digits.hasPrefix("9") {
            digits = "7" + digits
        } else if digits.count == 11 && digits.hasPrefix("7") {
            
        } else {
            if digits.count < 10 || digits.count > 15 {
                return nil
            }
        }
        
        return "+" + digits
    }
}
