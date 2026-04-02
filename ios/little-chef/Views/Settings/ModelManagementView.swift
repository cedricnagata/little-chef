//
//  ModelManagementView.swift
//  little-chef
//
//  Manage the local AI model
//

import SwiftUI

struct ModelManagementView: View {
    @EnvironmentObject var parsingService: MLXLLMService
    @EnvironmentObject var cookingService: MLXLLMService

    var body: some View {
        Form {
            // Cooking Model Section
            Section {
                if let modelInfo = cookingService.getModelInfo() {
                    InfoRow(label: "Name", value: modelInfo.name)
                    InfoRow(label: "Model", value: modelInfo.parameters)
                    InfoRow(label: "Quantization", value: modelInfo.quantization)
                }

                HStack {
                    Text("Status")
                    Spacer()
                    if cookingService.isLoaded {
                        Label("Loaded", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Label("Not Loaded", systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
            } header: {
                Text("Cooking Assistant Model (Bonsai)")
            }

            // Parsing Model Section
            Section {
                if let modelInfo = parsingService.getModelInfo() {
                    InfoRow(label: "Name", value: modelInfo.name)
                    InfoRow(label: "Model", value: modelInfo.parameters)
                    InfoRow(label: "Quantization", value: modelInfo.quantization)
                }

                HStack {
                    Text("Status")
                    Spacer()
                    if parsingService.isLoaded {
                        Label("Loaded", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Label("Not Loaded", systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
            } header: {
                Text("Recipe Parsing Model (Llama)")
            }

            // Model Actions Section
            Section {
                Button(action: loadModels) {
                    Label("Load All Models", systemImage: "arrow.down.circle")
                }
                .disabled(parsingService.isLoaded && cookingService.isLoaded)

                Button(action: unloadModels) {
                    Label("Unload All Models", systemImage: "arrow.up.circle")
                }
                .disabled(!parsingService.isLoaded && !cookingService.isLoaded)
            } header: {
                Text("Actions")
            } footer: {
                Text("Little Chef uses two specialized models: Bonsai 8B for cooking assistance with tool calling support, and Llama for recipe parsing. Models are downloaded automatically on first use.")
            }
        }
        .navigationTitle("Model Management")
        .navigationBarTitleDisplayMode(.large)
    }

    private func loadModels() {
        Task {
            do {
                async let parsing = parsingService.loadLocalModel()
                async let cooking = cookingService.loadLocalModel()
                _ = try await (parsing, cooking)
            } catch {
                print("Failed to load models: \(error)")
            }
        }
    }

    private func unloadModels() {
        parsingService.unloadModel()
        cookingService.unloadModel()
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        ModelManagementView()
            .environmentObject(MLXLLMService.parsingService)
            .environmentObject(MLXLLMService.cookingService)
    }
}
