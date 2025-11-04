//
//  ContentView.swift
//  little-chef
//
//  Updated for local-only operation with MLXLLM
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var llmService: MLXLLMService
    @State private var isLoadingModel = false
    @State private var loadError: String?

    var body: some View {
        Group {
            if llmService.isLoaded {
                MainView()
            } else if isLoadingModel {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading AI Model...")
                        .font(.headline)
                    if let error = loadError {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                            .padding()
                    }
                }
            } else {
                VStack(spacing: 20) {
                    Text("Welcome to Little Chef")
                        .font(.largeTitle)
                        .bold()
                    Text("AI-powered cooking assistant")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("Get Started") {
                        loadModel()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
            }
        }
        .task {
            // Attempt to load model on launch
            if !llmService.isLoaded {
                loadModel()
            }
        }
    }

    private func loadModel() {
        isLoadingModel = true
        loadError = nil
        Task {
            do {
                _ = try await llmService.loadLocalModel()
                isLoadingModel = false
            } catch {
                loadError = "Failed to load model: \(error.localizedDescription)"
                isLoadingModel = false
                print("❌ ContentView: Failed to load model: \(error)")
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(MLXLLMService.shared)
}
