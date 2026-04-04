//
//  ContentView.swift
//  little-chef
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var llmService: LLMService

    var body: some View {
        MainView()
            .overlay {
                if llmService.isLoadingModel {
                    ModelLoadingOverlay()
                }
            }
    }
}

#Preview {
    ContentView()
        .environmentObject(LLMService.shared)
        .environmentObject(CookingSessionManager())
        .environmentObject(VoiceAssistant())
}
