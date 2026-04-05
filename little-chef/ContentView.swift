//
//  ContentView.swift
//  little-chef
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        MainView()
    }
}

#Preview {
    ContentView()
        .environmentObject(LLMService.shared)
        .environmentObject(CookingSessionManager())
        .environmentObject(VoiceAssistant())
}
