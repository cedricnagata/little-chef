//
//  ModelManagementView.swift
//  little-chef
//
//  Manage the local AI model
//

import SwiftUI

struct ModelManagementView: View {
    @EnvironmentObject var llmService: MLXLLMService

    var body: some View {
        Form {
            // Model Info Section
            Section {
                if let modelInfo = llmService.getModelInfo() {
                    InfoRow(label: "Name", value: modelInfo.name)
                    InfoRow(label: "Parameters", value: modelInfo.parameters)
                    InfoRow(label: "Quantization", value: modelInfo.quantization)
                    InfoRow(label: "Context Length", value: "\(modelInfo.contextLength) tokens")
                } else {
                    Text("Model not loaded")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Model Information")
            }

            // Model Status Section
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    if llmService.isLoaded {
                        Label("Loaded", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Label("Not Loaded", systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
            } header: {
                Text("Status")
            }

            // Model Actions Section
            Section {
                if !llmService.isLoaded {
                    Button(action: {
                        loadModel()
                    }) {
                        Label("Load Model", systemImage: "arrow.down.circle")
                    }
                } else {
                    Button(action: {
                        unloadModel()
                    }) {
                        Label("Unload Model", systemImage: "arrow.up.circle")
                    }
                }
            } header: {
                Text("Actions")
            } footer: {
                Text("Unloading the model frees up memory. You can reload it anytime. The model is managed automatically by the app.")
            }
        }
        .navigationTitle("Model Management")
        .navigationBarTitleDisplayMode(.large)
    }

    private func loadModel() {
        Task {
            do {
                _ = try await llmService.loadLocalModel()
            } catch {
                print("Failed to load model: \(error)")
            }
        }
    }

    private func unloadModel() {
        llmService.unloadModel()
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
            .environmentObject(MLXLLMService.shared)
    }
}
