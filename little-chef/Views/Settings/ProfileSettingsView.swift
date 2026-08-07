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

    /// The shared store, for `cloudSyncStatus`. Not a `@StateObject` — this view doesn't own the
    /// singleton, it just needs to redraw if the status is ever published again.
    @ObservedObject private var dataManager = LocalDataManager.shared

    @State private var llmProvider: LLMProvider = .local
    /// Absolute `AVSpeechUtterance.rate`, where `AVSpeechUtteranceDefaultSpeechRate` is normal
    /// speed. Shown to the user as a multiple of that via `speechRateMultiplier`.
    @State private var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    @State private var voiceIdentifier = "com.apple.ttsbundle.Samantha-compact"
    @State private var autoSpeakResponses = true
    @State private var wakePhrase = "hey little chef"
    @State private var bigBroVoice = BigBroClient.defaultVoice
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    @State private var hasLoaded = false
    @State private var pendingDownload: CookingModelChoice?
    @State private var downloadAlertKind: DownloadAlertKind?
    @State private var pendingDeletion: CookingModelChoice?
    @State private var modelError: String?
    /// On-disk sizes, sampled rather than read live. Measuring one means walking the model's
    /// directory, and a SwiftUI body runs far too often to put a filesystem crawl inside it.
    @State private var modelSizes: [String: Int64] = [:]

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

    /// Whether the typed phrase is long enough for `WakeWord` to gate on. Checked here so the
    /// mode can be refused up front rather than starting a loop that answers nothing.
    private var wakePhraseIsUsable: Bool { !WakeWord(wakePhrase).isEmpty }

    /// Speaking through the Mac is not a separate opt-in — it follows the provider.
    ///
    /// Kokoro lives on the Mac, so the on-device provider cannot reach it whatever the user
    /// picked, and a user who deliberately routed inference through BigBro has no reason to
    /// want the system voice back. The stored preference is still written so older sessions
    /// and `VoiceAssistant` keep reading a consistent value.
    private var useBigBroSpeech: Bool { llmProvider == .bigBro }

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

                // The two providers speak through different engines, so the controls that apply
                // are disjoint: Kokoro on the Mac exposes named voices and no rate, AVSpeech on
                // the device exposes installed voices and a rate.
                if autoSpeakResponses {
                    if llmProvider == .bigBro {
                        BigBroVoicePicker(
                            client: llmService.bigBroClient,
                            bigBroVoice: $bigBroVoice
                        )
                    } else {
                        Picker("Voice", selection: $voiceIdentifier) {
                            // A saved voice that is no longer installed would otherwise drop out
                            // of the picker and silently reset the selection on the next render.
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
                }
            } header: {
                Text("Voice")
            }

            // MARK: - Hands-free
            Section {
                TextField("Wake word", text: $wakePhrase)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                if !wakePhraseIsUsable {
                    Label(
                        "Too short to gate on — a phrase this brief matches too much ordinary speech.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundColor(.orange)
                }

            } header: {
                Text("Hands-free")
            }

            // MARK: - iCloud
            Section {
                switch dataManager.cloudSyncStatus {
                case .syncing:
                    Label("Recipes sync to iCloud", systemImage: "checkmark.icloud")
                        .foregroundColor(.primary)
                case .localOnly(let reason):
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Not syncing — this device only", systemImage: "exclamationmark.icloud")
                            .foregroundColor(.orange)
                        Text(reason)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("iCloud")
            } footer: {
                if !dataManager.cloudSyncStatus.isSyncing {
                    Text("Recipes saved now stay on this device and will be lost if you delete the app. Check that you're signed in to iCloud with iCloud Drive turned on.")
                }
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
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            loadPreferences()
            // Cheap, and the only thing that notices a model deleted from the Files app or
            // evicted by the system since this screen was last open.
            llmService.refreshDownloadedModels()
            refreshModelSizes()
        }
        .onChange(of: llmService.downloadedModelIds) { _, _ in refreshModelSizes() }
        .onChange(of: llmProvider) { _, new in
            LLMService.shared.currentProvider = new
            saveIfLoaded()
        }
        .onChange(of: speechRate) { _, _ in saveIfLoaded() }
        .onChange(of: voiceIdentifier) { _, _ in saveIfLoaded() }
        .onChange(of: autoSpeakResponses) { _, _ in saveIfLoaded() }
        .onChange(of: wakePhrase) { _, _ in saveIfLoaded() }
        .onChange(of: bigBroVoice) { _, _ in saveIfLoaded() }
        .alert("Delete All Data", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { deleteAllData() }
        } message: {
            Text("This will permanently delete all your recipes and reset preferences. This cannot be undone.")
        }
        .alert(item: $downloadAlertKind) { kind in
            downloadAlert(for: kind)
        }
        .alert(
            "Remove \(pendingDeletion?.displayName ?? "Model")?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Remove", role: .destructive) {
                if let choice = pendingDeletion { deleteModel(choice) }
                pendingDeletion = nil
            }
        } message: {
            let freed = pendingDeletion
                .flatMap { modelSizes[$0.modelId] }
                .map { "Frees \(Self.byteFormatter.string(fromByteCount: $0)) of storage" }
                ?? "Frees the storage it's using"
            Text("\(freed) and unloads it from memory. The cooking assistant won't work on-device until you download it again.")
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

        if let modelError {
            Text(modelError)
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    // MARK: - Model Row

    /// One on-device model, with everything that can be done to it.
    ///
    /// Three states, not two. A model can be on disk without being in memory, and those cost the
    /// user different things — several gigabytes of storage versus several gigabytes of RAM. The
    /// row used to stop at "Downloaded", which left no way to hand the memory back short of
    /// killing the app, and no way to reclaim the disk at all.
    @ViewBuilder
    private func modelRow(for choice: CookingModelChoice, usage: String) -> some View {
        let isDownloading = llmService.currentlyLoadingModelId == choice.modelId
        let isDownloaded = llmService.downloadedModelIds.contains(choice.modelId)
        let isLoaded = llmService.loadedModelIds.contains(choice.modelId)

        VStack(alignment: .leading, spacing: 8) {
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
                } else if !isDownloaded {
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

            if isDownloaded && !isDownloading {
                HStack(spacing: 8) {
                    Label(
                        isLoaded ? "In memory" : "On disk",
                        systemImage: isLoaded ? "memorychip.fill" : "internaldrive"
                    )
                    .font(.caption2)
                    .foregroundColor(isLoaded ? .green : .secondary)

                    if let bytes = modelSizes[choice.modelId] {
                        Text(Self.byteFormatter.string(fromByteCount: bytes))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if isLoaded {
                        Button("Unload") { llmService.unloadModel(modelId: choice.modelId) }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .disabled(llmService.isGenerating)
                    } else {
                        Button("Load") { loadIntoMemory(choice) }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .disabled(llmService.isLoadingModel)
                    }

                    Button(role: .destructive) {
                        pendingDeletion = choice
                    } label: {
                        Image(systemName: "trash")
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(llmService.isGenerating || llmService.isLoadingModel)
                }
            }
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter
    }()

    private func refreshModelSizes() {
        var sizes: [String: Int64] = [:]
        for choice in CookingModelChoice.allCases {
            if let bytes = llmService.downloadedSize(of: choice.modelId) {
                sizes[choice.modelId] = bytes
            }
        }
        modelSizes = sizes
    }

    private func loadIntoMemory(_ choice: CookingModelChoice) {
        modelError = nil
        Task {
            do {
                try await llmService.preloadModel(modelId: choice.modelId)
            } catch {
                modelError = error.localizedDescription
            }
        }
    }

    private func deleteModel(_ choice: CookingModelChoice) {
        modelError = nil
        do {
            try llmService.deleteModel(modelId: choice.modelId)
            refreshModelSizes()
        } catch {
            modelError = error.localizedDescription
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
                    // Restore what was saved, rather than resetting to `.local` on every
                    // appearance. Forcing the default here meant a user who chose BigBro was
                    // switched back to on-device inference the next time they opened Settings,
                    // silently and without the picker appearing to change.
                    //
                    // A device with no on-device model can only be `.bigBro`, whatever is
                    // stored.
                    let provider: LLMProvider = LLMService.deviceSupportsLocalModels
                        ? prefs.llmProvider
                        : .bigBro
                    llmProvider = provider
                    speechRate = prefs.voiceSettings.speechRate
                    voiceIdentifier = prefs.voiceSettings.voiceIdentifier
                    autoSpeakResponses = prefs.voiceSettings.autoSpeakResponses
                    wakePhrase = prefs.voiceSettings.wakePhrase
                    bigBroVoice = prefs.voiceSettings.bigBroVoice
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
                useBigBroSpeech: useBigBroSpeech,
                wakePhrase: wakePhrase,
                bigBroVoice: bigBroVoice
            )
        )

        Task {
            do {
                try LocalDataManager.shared.updatePreferences(
                    speechRate: speechRate,
                    voiceIdentifier: voiceIdentifier,
                    autoSpeakResponses: autoSpeakResponses,
                    useBigBroSpeech: useBigBroSpeech,
                    wakePhrase: wakePhrase,
                    bigBroVoice: bigBroVoice,
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

/// Picks which Kokoro voice the paired Mac speaks with.
///
/// Observes the client directly: `ProfileSettingsView` watches `LLMService`, which does not
/// republish when its `BigBroClient` connects, so the status line would otherwise stay stale
/// until something else forced a redraw.
private struct BigBroVoicePicker: View {
    @ObservedObject var client: BigBroClient
    @Binding var bigBroVoice: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A closed list, not free text: the Mac fails synthesis on an unrecognized voice
            // id with no clue why, and the app has no dependency on Kokoro to enumerate them.
            // Offered even while disconnected so the choice can be made before pairing.
            Picker("Voice", selection: $bigBroVoice) {
                ForEach(Self.availableVoices, id: \.self) { voice in
                    Text(voice).tag(voice)
                }
            }

            Text(footnote)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Kokoro voices the Mac's speech backend ships, American English only — the rest are
    /// present in the model but unverified, and a cooking assistant has no use for a voice
    /// that might mispronounce every ingredient.
    private static let availableVoices: [String] = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole",
        "af_nova", "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric",
        "am_fenrir", "am_liam", "am_michael", "am_onyx", "am_puck", "am_santa",
    ]

    private var footnote: String {
        guard client.isConnected else {
            return "Connect to a BigBro Mac to use its voice. Until then responses are spoken with the on-device voice."
        }
        return "Speaking through \(client.connectedDevice?.name ?? "BigBro"). Falls back to the on-device voice if the Mac goes away."
    }
}

#Preview {
    NavigationStack {
        ProfileSettingsView()
            .environmentObject(LLMService.shared)
            .environmentObject(VoiceAssistant())
    }
}
