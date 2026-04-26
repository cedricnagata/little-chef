//
//  ProfileSettingsView.swift
//  little-chef
//

import SwiftUI
import AVFoundation

struct ProfileSettingsView: View {
    @EnvironmentObject var llmService: LLMService

    @State private var llmProvider: LLMProvider = .local
    @State private var speechRate: Float = 0.5
    @State private var voiceIdentifier = "com.apple.ttsbundle.Samantha-compact"
    @State private var autoSpeakResponses = true
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    @State private var hasLoaded = false

    private let iosVoices = [
        ("com.apple.ttsbundle.Samantha-compact", "Samantha"),
        ("com.apple.ttsbundle.Alex-compact", "Alex"),
        ("com.apple.ttsbundle.Victoria-compact", "Victoria"),
        ("com.apple.ttsbundle.Daniel-compact", "Daniel (UK)")
    ]

    var body: some View {
        Form {
            // MARK: - AI Provider
            Section {
                providerPickerSection
            } header: {
                Text("AI Provider")
            } footer: {
                providerFooter
            }

            // MARK: - Voice
            Section {
                Toggle("Auto-speak responses", isOn: $autoSpeakResponses)

                if autoSpeakResponses {
                    Picker("Voice", selection: $voiceIdentifier) {
                        ForEach(iosVoices, id: \.0) { voice in
                            Text(voice.1).tag(voice.0)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Speech Rate")
                            Spacer()
                            Text("\(speechRate, specifier: "%.1f")x")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $speechRate, in: 0.1...2.0, step: 0.1)
                            .tint(.orange)
                    }
                }
            } header: {
                Text("Voice")
            }

            // MARK: - Data
            Section {
                Button(role: .destructive) {
                    showingDeleteAlert = true
                } label: {
                    Label("Delete All Data", systemImage: "trash")
                }
                .disabled(isDeleting)
            } footer: {
                Text("Permanently deletes all saved recipes and resets preferences.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { loadPreferences() }
        .onChange(of: llmProvider) { _, new in
            LLMService.shared.currentProvider = new
            saveIfLoaded()
        }
        .onChange(of: speechRate) { _, _ in saveIfLoaded() }
        .onChange(of: voiceIdentifier) { _, _ in saveIfLoaded() }
        .onChange(of: autoSpeakResponses) { _, _ in saveIfLoaded() }
        .alert("Delete All Data", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { deleteAllData() }
        } message: {
            Text("This will permanently delete all your recipes and reset preferences. This cannot be undone.")
        }
    }

    // MARK: - Provider Picker Section

    @ViewBuilder
    private var providerPickerSection: some View {
        if LLMService.deviceSupportsLocalModels {
            Picker("Provider", selection: $llmProvider) {
                Text(LLMProvider.local.displayName).tag(LLMProvider.local)
                Text(LLMProvider.bigBro.displayName).tag(LLMProvider.bigBro)
            }
            .pickerStyle(.segmented)
        }
        if llmProvider == .local {
            localModelSection
        } else {
            BigBroPairingView(client: llmService.bigBroClient)
        }
    }

    @ViewBuilder
    private var providerFooter: some View {
        if !LLMService.deviceSupportsLocalModels {
            Text("On-Device requires 6 GB of memory. This device supports BigBro only.")
        } else if llmProvider == .local {
            Text("On-device inference. Bonsai 8B is used for recipe parsing; your selected model handles cooking assistance.")
        } else {
            Text("Routes all inference through your paired BigBro Mac. Tools are always available. No downloads required.")
        }
    }

    // MARK: - Local Model Section

    @ViewBuilder
    private var localModelSection: some View {
        modelRow(for: .bonsai8B, usage: "Recipe parsing")
        modelRow(for: .bonsai4B, usage: "Cooking assistant")

        if let error = llmService.loadError {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    // MARK: - Model Row

    @ViewBuilder
    private func modelRow(for choice: CookingModelChoice, usage: String) -> some View {
        let isDownloading = llmService.currentlyLoadingModelId == choice.modelId
        let isDownloaded = llmService.downloadedModelIds.contains(choice.modelId)

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.displayName)
                    .font(.subheadline)
                Text(usage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isDownloading {
                HStack(spacing: 6) {
                    ProgressView(value: llmService.loadProgress, total: 1.0)
                        .frame(width: 60)
                        .tint(.orange)
                    Text("\(Int(llmService.loadProgress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            } else if isDownloaded {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Button {
                    Task { try? await llmService.downloadModel(modelId: choice.modelId) }
                } label: {
                    Text("Download")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(llmService.isLoadingModel)
            }
        }
    }

    // MARK: - Data Operations

    private func saveIfLoaded() {
        guard hasLoaded else { return }
        savePreferences()
    }

    private func loadPreferences() {
        Task {
            do {
                let prefs = try LocalDataManager.shared.fetchPreferences().toUserPreferences()
                await MainActor.run {
                    let provider: LLMProvider = (!LLMService.deviceSupportsLocalModels && prefs.llmProvider == .local) ? .bigBro : prefs.llmProvider
                    llmProvider = provider
                    speechRate = prefs.voiceSettings.speechRate
                    voiceIdentifier = prefs.voiceSettings.voiceIdentifier
                    autoSpeakResponses = prefs.voiceSettings.autoSpeakResponses
                    LLMService.shared.currentProvider = provider
                    hasLoaded = true
                }
            } catch {
                print("Failed to load preferences: \(error)")
            }
        }
    }

    private func savePreferences() {
        Task {
            do {
                try LocalDataManager.shared.updatePreferences(
                    speechRate: speechRate,
                    voiceIdentifier: voiceIdentifier,
                    autoSpeakResponses: autoSpeakResponses,
                    llmProvider: llmProvider
                )
            } catch {
                print("Failed to save preferences: \(error)")
            }
        }
    }

    private func deleteAllData() {
        isDeleting = true
        Task {
            do {
                try LocalDataManager.shared.deleteAllRecipes()
                try LocalDataManager.shared.resetPreferences()
                await MainActor.run {
                    isDeleting = false
                    hasLoaded = false
                    loadPreferences()
                }
            } catch {
                print("Failed to delete data: \(error)")
                await MainActor.run { isDeleting = false }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ProfileSettingsView()
            .environmentObject(LLMService.shared)
    }
}
