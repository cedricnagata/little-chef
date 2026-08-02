//
//  ProfileSettingsView.swift
//  little-chef
//

import SwiftUI
import AVFoundation
import Network
import BigBroKit

/// Settings, split down the middle by where inference happens.
///
/// The provider picker is a tab, not just a switch: everything below it belongs to the side
/// that is selected. On-device shows the model's download and the voice this phone speaks with;
/// BigBro shows pairing, what the Mac has downloaded, and whether the Mac is doing the talking.
/// Mixing them — which is what a shared Voice section did — put a greyed-out "Use BigBro voice"
/// row in front of people who had no Mac, and hid the model manager behind a tab that had
/// nothing to do with it.
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
    @State private var pendingModel: CookingModelChoice?
    @State private var modelAlert: ModelAlertKind?
    @State private var modelError: String?

    private enum ModelAlertKind: Int, Identifiable {
        case wifiConfirm
        case cellularWarn
        case removeConfirm
        var id: Int { rawValue }
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
                    // Whose voice depends on which side is answering, so this follows the tab
                    // above rather than listing both and disabling one.
                    if llmProvider == .local {
                        deviceVoiceSettings
                    } else {
                        bigBroVoiceSettings
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
        .alert(item: $modelAlert) { kind in
            alertContent(for: kind)
        }
    }

    private func alertContent(for kind: ModelAlertKind) -> Alert {
        let name = pendingModel?.displayName ?? "The model"
        let size = pendingModel?.approximateSize ?? "several GB"
        switch kind {
        case .wifiConfirm:
            let msg = "\(name) is approximately \(size). Keep the app open until the download finishes."
            return Alert(
                title: Text("Download AI Model?"),
                message: Text(msg),
                primaryButton: .default(Text("Download")) { startPendingDownload() },
                secondaryButton: .cancel { pendingModel = nil }
            )
        case .cellularWarn:
            let msg = "\(name) is approximately \(size) and may use significant cellular data. Connect to Wi-Fi for best results."
            return Alert(
                title: Text("Cellular Connection"),
                message: Text(msg),
                primaryButton: .destructive(Text("Download Anyway")) { startPendingDownload() },
                secondaryButton: .cancel { pendingModel = nil }
            )
        case .removeConfirm:
            let msg = "Frees about \(size). Cooking chat and recipe parsing stop working on this device until \(name) is downloaded again."
            return Alert(
                title: Text("Remove \(name)?"),
                message: Text(msg),
                primaryButton: .destructive(Text("Remove")) { removePendingModel() },
                secondaryButton: .cancel { pendingModel = nil }
            )
        }
    }

    // MARK: - Model Download / Removal

    private func promptDownload(for choice: CookingModelChoice) {
        pendingModel = choice
        modelError = nil
        if NetworkPathMonitor.shared.isExpensive {
            modelAlert = .cellularWarn
        } else {
            modelAlert = .wifiConfirm
        }
    }

    private func promptRemoval(of choice: CookingModelChoice) {
        pendingModel = choice
        modelError = nil
        modelAlert = .removeConfirm
    }

    private func startPendingDownload() {
        guard let choice = pendingModel else { return }
        pendingModel = nil
        Task { try? await llmService.downloadModel(modelId: choice.modelId) }
    }

    private func removePendingModel() {
        guard let choice = pendingModel else { return }
        pendingModel = nil
        do {
            try llmService.removeModel(modelId: choice.modelId)
        } catch {
            modelError = "Couldn't remove the model: \(error.localizedDescription)"
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

        if let modelError {
            Text(modelError)
                .font(.caption)
                .foregroundColor(.red)
        }

        if let error = llmService.loadError {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    // MARK: - Model Row

    /// One model, and the two decisions the user owns about it.
    ///
    /// Download and remove only. Whether the model is *running* is shown but not offered:
    /// starting it belongs to opening a cooking session and stopping it to ending one, and a
    /// button that stopped it mid-session would only make the next question slow.
    @ViewBuilder
    private func modelRow(for choice: CookingModelChoice, usage: String) -> some View {
        let isDownloading = llmService.currentlyLoadingModelId == choice.modelId
        let isDownloaded = llmService.downloadedModelIds.contains(choice.modelId)
        let isRunning = llmService.runningModelIds.contains(choice.modelId)

        VStack(alignment: .leading, spacing: 6) {
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
                    Button(role: .destructive) {
                        promptRemoval(of: choice)
                    } label: {
                        Text("Remove")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
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

            statusLabel(downloading: isDownloading, downloaded: isDownloaded, running: isRunning, size: choice.approximateSize)
        }
    }

    /// The three states a model can be in, said plainly.
    ///
    /// "Downloaded" and "Running" are different things and the difference is the whole point of
    /// splitting them: one costs storage, the other costs memory, and the app only holds the
    /// second while a session is open.
    @ViewBuilder
    private func statusLabel(downloading: Bool, downloaded: Bool, running: Bool, size: String) -> some View {
        if downloading {
            // The same call does both, so what it is busy with depends on whether the weights
            // are already on disk — seconds of loading, or gigabytes of download.
            Label(
                downloaded ? "Starting — loading into memory" : "Downloading — keep the app open",
                systemImage: downloaded ? "bolt.horizontal.circle" : "arrow.down.circle"
            )
                .font(.caption2)
                .foregroundColor(.secondary)
        } else if running {
            Label("Running — in memory for this cooking session", systemImage: "bolt.circle.fill")
                .font(.caption2)
                .foregroundColor(.green)
        } else if downloaded {
            Label("Downloaded (\(size)) — starts when a cooking session opens", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundColor(.secondary)
        } else {
            Label("Not downloaded (\(size))", systemImage: "circle.dashed")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Voice

    /// The voice this phone speaks with — Apple's synthesizer, on device.
    ///
    /// Appears on both tabs, because it is the voice on both unless a connected Mac is doing
    /// the talking. Confining it to the on-device tab would put it out of reach entirely on a
    /// phone too small for on-device models, which is exactly the phone BigBro exists for.
    @ViewBuilder
    private var deviceVoiceSettings: some View {
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
    }

    @ViewBuilder
    private var bigBroVoiceSettings: some View {
        BigBroSpeechToggle(
            client: llmService.bigBroClient,
            useBigBroSpeech: $useBigBroSpeech
        )

        // Kept visible rather than hidden behind the toggle. This is the voice for every moment
        // the Mac isn't speaking — switched off, asleep, off the network — and on a device too
        // small for on-device models this tab is the only place these rows exist at all.
        deviceVoiceSettings

        Text("The device voice is used whenever the Mac isn't speaking.")
            .font(.caption)
            .foregroundColor(.secondary)
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

/// Opt-in to running the voice on a paired Mac — both directions of it.
///
/// This switches more than the voice: with it on, hands-free mode is BigBroKit's own loop,
/// which listens through the Mac's transcription and can be interrupted mid-answer, instead of
/// the app's wake-word-and-silence-timer path built on Apple's on-device recognizer. That is
/// worth saying plainly, because it moves recorded audio off the phone and onto the Mac.
///
/// Observes the client directly: `ProfileSettingsView` watches `LLMService`, which does not
/// republish when its `BigBroClient` connects, so the row would otherwise stay greyed out until
/// something else forced a redraw.
private struct BigBroSpeechToggle: View {
    @ObservedObject var client: BigBroClient
    @Binding var useBigBroSpeech: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Use BigBro for voice", isOn: $useBigBroSpeech)
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
            ? "Listening and speaking run on \(client.connectedDevice?.name ?? "BigBro") — recordings go to that Mac over your Wi-Fi, and hands-free mode can be interrupted mid-answer. Falls back to the on-device voice if the Mac goes away."
            : "Listening and speaking stay on this device."
    }
}

#Preview {
    NavigationStack {
        ProfileSettingsView()
            .environmentObject(LLMService.shared)
            .environmentObject(VoiceAssistant())
    }
}
