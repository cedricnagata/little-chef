//
//  Config.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/10/25.
//

import Foundation

struct Config {
    // MARK: - API Configuration
    
    /// Returns the base URL for the API based on the current environment
    static var baseURL: String {
        #if DEBUG
            // In debug mode, try to load from Config.plist first, fall back to localhost
            if let url = loadConfigValue(key: "LOCAL_API_URL") {
                print("Using local API URL from Config.plist: \(url)")
                return url
            }
            print("⚠️ Using default localhost URL")
            return "http://localhost:8000"
        #else
            // In release mode, MUST have PRODUCTION_API_URL in Config.plist
            guard let url = loadConfigValue(key: "PRODUCTION_API_URL") else {
                fatalError("PRODUCTION_API_URL not found in Config.plist.")
            }
            print("📱 Using production API URL from Config.plist: \(url)")
            return url
        #endif
    }
    
    // MARK: - Private Methods
    
    /// Loads a value from Config.plist for the given key
    private static func loadConfigValue(key: String) -> String? {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: path),
              let value = plist[key] as? String,
              !value.isEmpty else {
            return nil
        }
        return value
    }
    
    // MARK: - Environment Detection
    
    /// Returns true if running in debug/development mode
    static var isDebug: Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }
    
    /// Returns a string representation of the current environment
    static var environment: String {
        return isDebug ? "Development" : "Production"
    }
}

// MARK: - Config Extensions for Logging

extension Config {
    /// Prints current configuration for debugging
    static func logConfiguration() {
        print("🔧 Configuration:")
        print("   Environment: \(environment)")
        print("   Base URL: \(baseURL)")
        print("   Debug Mode: \(isDebug)")
    }
}
