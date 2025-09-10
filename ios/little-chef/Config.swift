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
            // In debug mode, try to load from local config first, fall back to localhost
            if let localURL = loadLocalConfig() {
                return localURL
            }
            return "http://localhost:8000"
        #else
            // In release mode, use production URL
            return "https://your-production-api.com"  // Replace with your actual production URL
        #endif
    }
    
    // MARK: - Private Methods
    
    /// Loads the local development URL from Config.plist if it exists
    private static func loadLocalConfig() -> String? {
        guard let path = Bundle.main.path(forResource: "Config", ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: path),
              let url = plist["LOCAL_API_URL"] as? String else {
            print("⚠️ Config.plist not found or LOCAL_API_URL not set. Using default localhost.")
            return nil
        }
        
        print("📱 Using local API URL from Config.plist: \(url)")
        return url
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
