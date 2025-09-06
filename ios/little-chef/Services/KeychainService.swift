//
//  KeychainService.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import Foundation
import Security

class KeychainService {
    static let shared = KeychainService()
    
    private init() {}
    
    private let serviceName = "com.littlechef.app"
    
    // MARK: - Token Storage
    func saveAccessToken(_ token: String) -> Bool {
        return save(key: "access_token", value: token)
    }
    
    func saveRefreshToken(_ token: String) -> Bool {
        return save(key: "refresh_token", value: token)
    }
    
    func getAccessToken() -> String? {
        return get(key: "access_token")
    }
    
    func getRefreshToken() -> String? {
        return get(key: "refresh_token")
    }
    
    func deleteTokens() -> Bool {
        let accessDeleted = delete(key: "access_token")
        let refreshDeleted = delete(key: "refresh_token")
        return accessDeleted && refreshDeleted
    }
    
    // MARK: - Generic Keychain Operations
    private func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        
        // Delete existing item first
        delete(key: key)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    private func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return string
    }
    
    @discardableResult
    private func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
