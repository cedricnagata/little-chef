//
//  little_chefApp.swift
//  little-chef
//
//  Created by Cedric Nagata on 9/5/25.
//

import SwiftUI

@main
struct little_chefApp: App {
    @StateObject private var authManager = AuthManager()
    @StateObject private var cookingSessionManager = CookingSessionManager()
    @StateObject private var voiceAssistant = VoiceAssistant()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authManager)
                .environmentObject(cookingSessionManager)
                .environmentObject(voiceAssistant)
        }
    }
}
