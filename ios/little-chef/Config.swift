//
//  Config.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/10/25.
//

import Foundation

struct Config {
    // MARK: - API Configuration

    /// Returns the Recipe Parser URL for parsing recipes from URLs, text, or images
    static var recipeParserURL: String {
        #if DEBUG
            // In debug mode, try to load from Config.plist first, fall back to localhost
            if let url = loadConfigValue(key: "RECIPE_PARSER_URL_DEV") {
                return url
            }
            return "http://localhost:3000"
        #else
            // In release mode, MUST have RECIPE_PARSER_URL_PROD in Config.plist
            guard let url = loadConfigValue(key: "RECIPE_PARSER_URL_PROD") else {
                fatalError("RECIPE_PARSER_URL_PROD not found in Config.plist.")
            }
            return url
        #endif
    }

    /// Returns the Cooking Assistant WebSocket URL for real-time cooking assistance
    static var cookingAssistantURL: String {
        #if DEBUG
            // In debug mode, try to load from Config.plist first
            if let url = loadConfigValue(key: "COOKING_ASSISTANT_URL_DEV") {
                return url
            }
            return "ws://localhost:3001"
        #else
            // In release mode, MUST have COOKING_ASSISTANT_URL_PROD in Config.plist
            guard let url = loadConfigValue(key: "COOKING_ASSISTANT_URL_PROD") else {
                fatalError("COOKING_ASSISTANT_URL_PROD not found in Config.plist.")
            }
            return url
        #endif
    }

    /// Returns the Recipe Editor URL for AI-powered recipe editing
    static var recipeEditorURL: String? {
        #if DEBUG
            // In debug mode, try to load from Config.plist first
            if let url = loadConfigValue(key: "RECIPE_EDITOR_URL_DEV") {
                return url
            }
            return nil
        #else
            // In release mode, MUST have RECIPE_EDITOR_URL_PROD in Config.plist
            guard let url = loadConfigValue(key: "RECIPE_EDITOR_URL_PROD") else {
                return nil
            }
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
        print("🔧 LittleChef Configuration (\(environment) mode)")
        print("   Recipe Parser: \(recipeParserURL)")
        print("   Cooking Assistant: \(cookingAssistantURL)")
        print("   Recipe Editor: \(recipeEditorURL ?? "Not configured")")
    }
}
