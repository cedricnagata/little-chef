//
//  ProfileSettingsView.swift
//  little-chef
//

import SwiftUI
import AVFoundation
import Network
import BigBroKit

struct ProfileSettingsView: View {
    @EnvironmentObject var llmService: LLMService
    @EnvironmentObject var voiceAssistant: VoiceAssistant

    @State private var llmProvider: LLMProvider = .local
    /// Absolute `AVSpeechUtterance.rate`, where `AVSpeechUtteranceDefaultSpeechRate` is normal
    /// speed. Shown to the user as a multiple of that via `speechRateMultiplier`.
    @State private var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    @State private var voiceIdentifier = "com.apple.ttsbundle.Samantha-compact"
    @State private var autoSpeakResponses = true
    @State private var useBigBroSpeech = false
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    @State private var hasLoaded = false
    @State private var pendingDownload: CookingModelChoice?
    @State private var downloadAlertKind: DownloadAlertKind?

    private enum DownloadAlertKind: Identifiable {
        case wifiConfirm
        case cellularWarn
        var id: Int { self == .wifiConfirm ? 0 : 1 }
    }

    /// Voices actually installed on this device.
    ///
    /// This was previously a hardcoded list of legacy `com.apple.ttsbundle.*` identifiers.
    /// Modern iOS ships `com.apple.voice.compact.*` forms and the old ones are frequently
    /// absent, so `AVSpeechSynthesisVoice(identifier:)` returned nil and the synthesizer fell
    /// back to the system default without any error — the picker changed but the voice did not.
    /// Enumerating the device guarantees every option resolves.
    private var availableVoices: [AVSpeechSynthesisVoice] {
        let deviceLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        let wanted = Set(["en", deviceLanguage])
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in wanted.contains { voice.language.hasPrefix($0) } }
            .sorted { ($0.name, $0.language) < ($1.name, $1.language) }
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let language = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        return "\(voice.name) (\(language))"
    }

    /// Presents the stored rate as a multiple of normal speed, so "normal" reads as 1.0x.
    ///
    /// `AVSpeechUtterance.rate` runs 0.0–1.0 with 0.5 as normal, which surfaced as "0.5x" and
    /// made the top half of the old 0.1–2.0 slider dead: every value above 1.0 saturated at
    /// maximum and sounded identical. Because the default is exactly half the maximum, a
    /// 0.5x–2.0x multiplier covers the whole usable range with none of it wasted.
    private var speechRateMultiplier: Binding<Float> {
        Binding(
            get: { speechRate / AVSpeechUtteranceDefaultSpeechRate },
            set: { speechRate = $0 * AVSpeechUtteranceDefaultSpeechRate }
        )
    }

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
                        // A saved voice that is no longer installed would otherwise drop out of
                        // the picker and silently reset the selection on the next render.
                        if !availableVoices.contains(where: { $0.identifier == voiceIdentifier }) {
                            Text("System Default").tag(voiceIdentifier)
                            Divider()
                        }
                        ForEach(availableVoices, id: \.identifier) { voice in
                            Text(voiceLabel(voice)).tag(voice.identifier)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Speech Rate")
                            Spacer()
                            Text("\(speechRateMultiplier.wrappedValue, specifier: "%.1f")x")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: speechRateMultiplier, in: 0.5...2.0, step: 0.1)
                            .tint(.orange)
                    }

                    BigBroSpeechToggle(
                        client: llmService.bigBroClient,
                        useBigBroSpeech: $useBigBroSpeech
                    )
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

            // MARK: - About
            Section {
                Text("Recipes imported from URLs remain the property of their original authors and are stored locally on your device for personal use only.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } header: {
                Text("About")
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
        .onChange(of: useBigBroSpeech) { _, _ in saveIfLoaded() }
        .alert("Delete All Data", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { deleteAllData() }
        } message: {
            Text("This will permanently delete all your recipes and reset preferences. This cannot be undone.")
        }
        .alert(item: $downloadAlertKind) { kind in
            downloadAlert(for: kind)
        }
    }

    private func downloadAlert(for kind: DownloadAlertKind) -> Alert {
        let name = pendingDownload?.displayName ?? "The model"
        let size = pendingDownload?.approximateSize ?? "several GB"
        switch kind {
        case .wifiConfirm:
            let msg = "\(name) is approximately \(size). Keep the app open until the download finishes."
            return Alert(
                title: Text("Download AI Model?"),
                message: Text(msg),
                primaryButton: .default(Text("Download")) { startPendingDownload() },
                secondaryButton: .cancel { pendingDownload = nil }
            )
        case .cellularWarn:
            let msg = "\(name) is approximately \(size) and may use significant cellular data. Connect to Wi-Fi for best results."
            return Alert(
                title: Text("Cellular Connection"),
                message: Text(msg),
                primaryButton: .destructive(Text("Download Anyway")) { startPendingDownload() },
                secondaryButton: .cancel { pendingDownload = nil }
            )
        }
    }

    // MARK: - Download Gating

    private func promptDownload(for choice: CookingModelChoice) {
        pendingDownload = choice
        if NetworkPathMonitor.shared.isExpensive {
            downloadAlertKind = .cellularWarn
        } else {
            downloadAlertKind = .wifiConfirm
        }
    }

    private func startPendingDownload() {
        guard let choice = pendingDownload else { return }
        pendingDownload = nil
        Task { try? await llmService.downloadModel(modelId: choice.modelId) }
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
        if let model = LLMService.supportedOnDeviceModel, llmProvider == .local {
            if model.isFullCapability {
                Text("On-device inference. \(model.displayName) handles both recipe parsing and cooking assistance.")
            } else {
                Text("On-device inference. \(model.displayName) powers the cooking assistant only — recipe import works from recipe websites (structured data), and timers are set manually.")
            }
        } else if !LLMService.deviceSupportsLocalModels {
            Text("On-device AI requires at least 3 GB of memory. This device supports BigBro only. Without BigBro, you can still import recipes from websites and set timers manually.")
        } else {
            Text("Routes all inference through your paired BigBro Mac. Tools are always available. No downloads required.")
        }
    }

    // MARK: - Local Model Section

    @ViewBuilder
    private var localModelSection: some View {
        if let model = LLMService.supportedOnDeviceModel {
            modelRow(
                for: model,
                usage: model.isFullCapability
                    ? "Recipe parsing & cooking assistant"
                    : "Cooking assistant only (no recipe import or timer tools)"
            )
        }

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
                    promptDownload(for: choice)
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
                    let provider: LLMProvider = LLMService.deviceSupportsLocalModels ? .local : .bigBro
                    llmProvider = provider
                    speechRate = prefs.voiceSettings.speechRate
                    voiceIdentifier = prefs.voiceSettings.voiceIdentifier
                    autoSpeakResponses = prefs.voiceSettings.autoSpeakResponses
                    useBigBroSpeech = prefs.voiceSettings.useBigBroSpeech
                    LLMService.shared.currentProvider = provider
                    hasLoaded = true
                }
            } catch {
                dprint("Failed to load preferences: \(error)")
            }
        }
    }

    private func savePreferences() {
        // Push straight to the assistant as well as persisting.
        //
        // VoiceAssistant.voiceSettings is otherwise only ever fed from
        // CookingSession.userPreferences, which is a `let` snapshot taken once when a cooking
        // session starts and never refreshed from SwiftData. Without this, an edit here would
        // not take effect until the session was ended and restarted.
        voiceAssistant.updateVoiceSettings(
            LocalVoiceSettings(
                speechRate: speechRate,
                voiceIdentifier: voiceIdentifier,
                autoSpeakResponses: autoSpeakResponses,
                useBigBroSpeech: useBigBroSpeech
            )
        )

        Task {
            do {
                try LocalDataManager.shared.updatePreferences(
                    speechRate: speechRate,
                    voiceIdentifier: voiceIdentifier,
                    autoSpeakResponses: autoSpeakResponses,
                    useBigBroSpeech: useBigBroSpeech,
                    llmProvider: llmProvider
                )
            } catch {
                dprint("Failed to save preferences: \(error)")
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
                dprint("Failed to delete data: \(error)")
                await MainActor.run { isDeleting = false }
            }
        }
    }
}

/// Opt-in to speaking through a paired Mac.
///
/// Observes the client directly: `ProfileSettingsView` watches `LLMService`, which does not
/// republish when its `BigBroClient` connects, so the row would otherwise stay greyed out until
/// something else forced a redraw.
private struct BigBroSpeechToggle: View {
    @ObservedObject var client: BigBroClient
    @Binding var useBigBroSpeech: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Use BigBro voice", isOn: $useBigBroSpeech)
                .disabled(!client.isConnected)

            Text(footnote)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var footnote: String {
        if !client.isConnected {
            return "Connect to a BigBro Mac to use its voice."
        }
        return useBigBroSpeech
            ? "Speaking through \(client.connectedDevice?.name ?? "BigBro"). Falls back to the on-device voice if the Mac goes away."
            : "Speaking with the on-device voice."
    }
}

#Preview {
    NavigationStack {
        ProfileSettingsView()
            .environmentObject(LLMService.shared)
            .environmentObject(VoiceAssistant())
    }
}
