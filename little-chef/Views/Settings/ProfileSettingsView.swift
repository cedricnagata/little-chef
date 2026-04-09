//
//  ProfileSettingsView.swift
//  little-chef
//

import SwiftUI
import AVFoundation

struct ProfileSettingsView: View {
    @EnvironmentObject var llmService: LLMService

    @State private var measurementSystem = "imperial"
    @State private var dietaryRestrictions: [String] = []
    @State private var speechRate: Float = 0.5
    @State private var voiceIdentifier = "com.apple.ttsbundle.Samantha-compact"
    @State private var autoSpeakResponses = true
    @State private var cookingModel: CookingModelChoice = .bonsai8B
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    @State private var hasLoaded = false

    private let iosVoices = [
        ("com.apple.ttsbundle.Samantha-compact", "Samantha (English US)"),
        ("com.apple.ttsbundle.Alex-compact", "Alex (English US)"),
        ("com.apple.ttsbundle.Victoria-compact", "Victoria (English US)"),
        ("com.apple.ttsbundle.Daniel-compact", "Daniel (English UK)")
    ]

    var body: some View {
        Form {
            // MARK: - AI Models
            Section {
                Picker("Cooking Assistant", selection: $cookingModel) {
                    ForEach(CookingModelChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }

                if !cookingModel.supportsTools {
                    Label("Timer tools are not available with this model", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                // Per-model status rows
                ForEach(CookingModelChoice.allCases, id: \.self) { choice in
                    modelRow(for: choice)
                }

                if let error = llmService.loadError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } header: {
                Text("AI Models")
            } footer: {
                Text("Bonsai 8B is always used for recipe parsing. The cooking assistant uses your selected model. Models are downloaded to disk and loaded into memory on demand — download here to avoid wait times.")
            }

            // MARK: - Cooking Preferences
            Section {
                Picker("Measurement System", selection: $measurementSystem) {
                    Text("Imperial (cups, oz, °F)").tag("imperial")
                    Text("Metric (ml, g, °C)").tag("metric")
                }
                .pickerStyle(SegmentedPickerStyle())
            } header: {
                Text("Measurements")
            }

            Section {
                ForEach(dietaryRestrictions, id: \.self) { restriction in
                    HStack {
                        Text(restriction)
                        Spacer()
                        Button {
                            dietaryRestrictions.removeAll { $0 == restriction }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                }

                NavigationLink("Add Restriction") {
                    DietaryRestrictionPicker(selectedRestrictions: $dietaryRestrictions)
                }
            } header: {
                Text("Dietary Restrictions")
            }

            // MARK: - Voice
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speech Rate")
                    HStack {
                        Text("Slow").font(.caption)
                        Slider(value: $speechRate, in: 0.1...2.0, step: 0.1)
                        Text("Fast").font(.caption)
                    }
                    Text("\(speechRate, specifier: "%.1f")x")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Picker("Voice", selection: $voiceIdentifier) {
                    ForEach(iosVoices, id: \.0) { voice in
                        Text(voice.1).tag(voice.0)
                    }
                }
                .pickerStyle(MenuPickerStyle())

                Toggle("Auto-speak responses", isOn: $autoSpeakResponses)
            } header: {
                Text("Voice")
            }

            // MARK: - Data Management
            Section {
                Button(role: .destructive) {
                    showingDeleteAlert = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Delete All Data")
                    }
                }
                .disabled(isDeleting)
            } footer: {
                Text("Permanently deletes all recipes and resets preferences.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .onAppear { loadPreferences() }
        .onChange(of: measurementSystem) { _, _ in saveIfLoaded() }
        .onChange(of: dietaryRestrictions) { _, _ in saveIfLoaded() }
        .onChange(of: speechRate) { _, _ in saveIfLoaded() }
        .onChange(of: voiceIdentifier) { _, _ in saveIfLoaded() }
        .onChange(of: autoSpeakResponses) { _, _ in saveIfLoaded() }
        .onChange(of: cookingModel) { _, _ in saveIfLoaded() }
        .alert("Delete All Data", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { deleteAllData() }
        } message: {
            Text("This will permanently delete all your recipes and reset preferences. This cannot be undone.")
        }
    }

    // MARK: - Model Row

    @ViewBuilder
    private func modelRow(for choice: CookingModelChoice) -> some View {
        let isDownloading = llmService.currentlyLoadingModelId == choice.modelId
        let isDownloaded = llmService.downloadedModelIds.contains(choice.modelId)

        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.displayName)
                    .font(.subheadline)

                if choice == .bonsai8B {
                    Text("Recipe parsing + cooking")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("Cooking only (no tools)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
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
                    Task {
                        try? await llmService.downloadModel(modelId: choice.modelId)
                    }
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
                let dataManager = LocalDataManager.shared
                let prefsEntity = try dataManager.fetchPreferences()
                let prefs = prefsEntity.toUserPreferences()

                await MainActor.run {
                    measurementSystem = prefs.measurementSystem
                    dietaryRestrictions = prefs.dietaryRestrictions
                    speechRate = prefs.voiceSettings.speechRate
                    voiceIdentifier = prefs.voiceSettings.voiceIdentifier
                    autoSpeakResponses = prefs.voiceSettings.autoSpeakResponses
                    cookingModel = prefs.cookingModel
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
                let dataManager = LocalDataManager.shared
                try dataManager.updatePreferences(
                    measurementSystem: measurementSystem,
                    dietaryRestrictions: dietaryRestrictions,
                    speechRate: speechRate,
                    voiceIdentifier: voiceIdentifier,
                    autoSpeakResponses: autoSpeakResponses,
                    cookingModel: cookingModel
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
                let dataManager = LocalDataManager.shared
                try dataManager.deleteAllRecipes()
                try dataManager.resetPreferences()
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

// MARK: - Dietary Restriction Picker

struct DietaryRestrictionPicker: View {
    @Binding var selectedRestrictions: [String]
    @Environment(\.dismiss) private var dismiss

    private let commonRestrictions = [
        "Vegetarian", "Vegan", "Gluten-Free", "Dairy-Free",
        "Nut-Free", "Shellfish-Free", "Kosher", "Halal",
        "Low-Carb", "Keto", "Paleo"
    ]

    var body: some View {
        List {
            ForEach(commonRestrictions, id: \.self) { restriction in
                Button {
                    if !selectedRestrictions.contains(restriction) {
                        selectedRestrictions.append(restriction)
                        dismiss()
                    }
                } label: {
                    HStack {
                        Text(restriction)
                        Spacer()
                        if selectedRestrictions.contains(restriction) {
                            Image(systemName: "checkmark")
                                .foregroundColor(.orange)
                        }
                    }
                }
                .foregroundColor(.primary)
            }
        }
        .navigationTitle("Add Restriction")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        ProfileSettingsView()
            .environmentObject(LLMService.shared)
    }
}
