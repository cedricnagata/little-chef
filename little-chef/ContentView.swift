//
//  ContentView.swift
//  little-chef
//
//  Updated for local-only operation with MLXLLM
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var parsingService: MLXLLMService
    @EnvironmentObject var cookingService: MLXLLMService

    var body: some View {
        // Models are loaded lazily when needed - don't pre-load to save memory
        MainView()
    }
}

#Preview {
    ContentView()
        .environmentObject(MLXLLMService.parsingService)
        .environmentObject(MLXLLMService.cookingService)
        .environmentObject(CookingSessionManager())
        .environmentObject(VoiceAssistant())
}
