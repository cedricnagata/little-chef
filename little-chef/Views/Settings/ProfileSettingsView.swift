//
//  ProfileSettingsView.swift
//  little-chef
//
//  The Settings tab: AI provider and models, voice, exporting and importing the
//  profile, and Delete All Data.
//

import SwiftUI
import AVFoundation
import Network
import BigBroKit
import UniformTypeIdentifiers

struct ProfileSettingsView: View {
    @EnvironmentObject var llmService: LLMService
    @EnvironmentObject var voiceAssistant: VoiceAssistant

    @State private var llmProvider: LLMProvider = .local
    /// Absolute `AVSpeechUtterance.rate`, where `AVSpeechUtteranceDefaultSpeechRate` is normal
    /// speed. Shown to the user as a multiple of that via `speechRateMultiplier`.
    @State private var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
    @State private var voiceIdentifier = AVSpeechSynthesisVoice.automaticIdentifier
    /// The voices to offer, re-read when one is downloaded or deleted in the Settings app.
    @State private var voices: [AVSpeechSynthesisVoice] = []
    /// Plays the sample when a voice or rate is chosen.
    @State private var sampleSpeaker = OnDeviceSpeaker()
    @State private var autoSpeakResponses = true
    @State private var bigBroVoice = BigBroClient.defaultVoice
    @State private var hasLoaded = false
    @State private var pendingDownload: CookingModelChoice?
    @State private var downloadAlertKind: DownloadAlertKind?
    @State private var pendingDeletion: CookingModelChoice?
    @State private var modelError: String?
    @State private var confirmingDeleteAll = false
    @State private var deleteAllError: String?
    /// The profile being exported, while the save sheet is up.
    @State private var exportDocument: ProfileBackupDocument?
    @State private var choosingImportFile = false
    /// A profile read from a file, waiting for the user to confirm the import.
    @State private var pendingImport: ProfileBackup?
    /// The outcome of the last export or import, and whether it failed.
    @State private var profileMessage: (text: String, isError: Bool)?
    /// On-disk sizes, sampled rather than read live. Measuring one means walking the model's
    /// directory, and a SwiftUI body runs far too often to put a filesystem crawl inside it.
    @State private var modelSizes: [String: Int64] = [:]

    private enum DownloadAlertKind: Identifiable {
        case wifiConfirm
        case cellularWarn
        var id: Int { self == .wifiConfirm ? 0 : 1 }
    }

    /// The voices to offer: the device's language and English, novelty voices left out
    /// (`AVSpeechSynthesisVoice.choosable`), best quality first.
    ///
    /// Enumerated from the device rather than listed by hand: a hardcoded list of legacy
    /// `com.apple.ttsbundle.*` identifiers mostly didn't resolve on modern iOS, so the picker
    /// changed and the voice did not.
    private static func installedVoices() -> [AVSpeechSynthesisVoice] {
        let deviceLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        let wanted = Set(["en", deviceLanguage])
        return AVSpeechSynthesisVoice.choosable
            .filter { voice in wanted.contains { voice.language.hasPrefix($0) } }
            .sorted { ($1.quality.rawValue, $0.name, $0.language) < ($0.quality.rawValue, $1.name, $1.language) }
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let language = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        return [voice.name, voice.qualityName].compactMap { $0 }.joined(separator: " ") + " (\(language))"
    }

    private var automaticLabel: String {
        guard let voice = AVSpeechSynthesisVoice.bestInstalled() else { return "Automatic" }
        return "Automatic (\([voice.name, voice.qualityName].compactMap { $0 }.joined(separator: " ")))"
    }

    private func playSample() {
        let voice = AVSpeechSynthesisVoice.resolving(voiceIdentifier)
        let rate = speechRate
        sampleSpeaker.stop()
        // Playback, so the sample is heard with the ring switch on silent. No cook is running
        // while Settings is open, so nothing else holds the audio session.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        Task { await sampleSpeaker.speak("Preheat the oven to 200 degrees, then chop the onion.", voice: voice, rate: rate) }
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
                        // The sample plays from the user's choice only, not from loading the form.
                        Picker("Voice", selection: Binding(
                            get: { voiceIdentifier },
                            set: { voiceIdentifier = $0; playSample() }
                        )) {
                            Text(automaticLabel).tag(AVSpeechSynthesisVoice.automaticIdentifier)
                            // A saved voice since deleted in the Settings app stays selectable
                            // rather than silently resetting the choice; it speaks as automatic.
                            if !AVSpeechSynthesisVoice.isAutomatic(voiceIdentifier),
                               !voices.contains(where: { $0.identifier == voiceIdentifier }) {
                                Text("Not installed (using automatic)").tag(voiceIdentifier)
                            }
                            Divider()
                            ForEach(voices, id: \.identifier) { voice in
                                Text(voiceLabel(voice)).tag(voice.identifier)
                            }
                        }

                        Button("Play Sample", systemImage: "speaker.wave.2", action: playSample)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Speech Rate")
                                Spacer()
                                Text("\(speechRateMultiplier.wrappedValue, specifier: "%.1f")x")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: speechRateMultiplier, in: 0.5...2.0, step: 0.1) { editing in
                                if !editing { playSample() }
                            }
                                .tint(.orange)
                        }
                    }
                }
            } header: {
                Text("Voice")
            } footer: {
                if autoSpeakResponses, llmProvider != .bigBro {
                    Text("iOS doesn't let apps use Siri's voice. For the most natural one, download an Enhanced or Premium voice in the Settings app under Accessibility → Spoken Content → Voices; it appears here when it's done.")
                }
            }

            // MARK: - Your Data
            Section {
                Button("Export Profile") { exportProfile() }
                    .fileExporter(
                        isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                        document: exportDocument,
                        contentType: .json,
                        defaultFilename: ProfileBackup.suggestedFileName()
                    ) { result in
                        switch result {
                        case .success: profileMessage = ("Profile exported.", false)
                        case .failure(let error): profileMessage = (error.localizedDescription, true)
                        }
                    }

                // The importer on its own button: two file presenters on one view only show one.
                Button("Import Profile") { choosingImportFile = true }
                    .fileImporter(isPresented: $choosingImportFile, allowedContentTypes: [.json]) { result in
                        readProfile(result)
                    }

                if let profileMessage {
                    Text(profileMessage.text)
                        .font(.caption)
                        .foregroundColor(profileMessage.isError ? .red : .secondary)
                }

                Button("Delete All Data", role: .destructive) { confirmingDeleteAll = true }
                    .disabled(llmService.isGenerating || llmService.isLoadingModel)

                if let deleteAllError {
                    Text(deleteAllError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } header: {
                Text("Your Data")
            } footer: {
                Text("Everything is kept on this device only. Export Profile saves your recipes, inventory, shopping list and settings to a file. Import it on another device, or after reinstalling, to bring them back; it adds to what's already here. Delete All Data removes all of it, plus downloaded AI models and paired Macs.")
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
        .onAppear { voices = Self.installedVoices() }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            voices = Self.installedVoices()
        }
        .onChange(of: autoSpeakResponses) { _, _ in saveIfLoaded() }
        .onChange(of: bigBroVoice) { _, _ in saveIfLoaded() }
        .alert("Delete All Data?", isPresented: $confirmingDeleteAll) {
            Button("Delete All Data", role: .destructive) { deleteAllData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your recipes, inventory, shopping list and settings, downloaded AI models, and paired Macs will be deleted from this device. Export your profile first if you want to keep them. This can't be undone.")
        }
        .alert(
            "Import This Profile?",
            isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
            presenting: pendingImport
        ) { backup in
            Button("Import") { importProfile(backup) }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: { backup in
            Text(importDescription(backup))
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
        Task { await llmService.downloadModel(modelId: choice.modelId) }
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
        if let model = llmService.activeOnDeviceModel, llmProvider == .local {
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
        // Only offered where there is a choice to make: a device with the memory for the 27B.
        // Switching takes effect on the next request, which unloads the other model first.
        if LLMService.onDeviceModelOptions.count > 1 {
            Picker("Model", selection: $llmService.preferredOnDeviceModel) {
                ForEach(LLMService.onDeviceModelOptions, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .disabled(llmService.isGenerating || llmService.isLoadingModel)
        }

        if let model = llmService.activeOnDeviceModel {
            modelRow(
                for: model,
                usage: model.isFullCapability
                    ? "Recipe parsing & cooking assistant"
                    : "Cooking assistant only (no recipe import or timer tools)"
            )
        }

        if let error = llmService.downloadError ?? llmService.loadError {
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
        let isDownloading = llmService.downloadingModelId == choice.modelId
            || llmService.currentlyLoadingModelId == choice.modelId
        let progress = llmService.downloadingModelId == choice.modelId
            ? llmService.downloadProgress : llmService.loadProgress
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
                        ProgressView(value: progress, total: 1.0)
                            .frame(width: 60)
                            .tint(.orange)
                        Text("\(Int(progress * 100))%")
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
                    .disabled(llmService.isLoadingModel || llmService.downloadingModelId != nil)
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

    /// Everything the app keeps about the user, gone: recipes, preferences, inventory and
    /// shopping list, downloaded models and model settings, and every
    /// paired Mac.
    ///
    /// Models first, because it is the step that can refuse — mid-answer or mid-download — and
    /// refusing before anything is deleted beats deleting the recipes and then reporting that
    /// the rest didn't happen.
    private func deleteAllData() {
        deleteAllError = nil
        do {
            try llmService.deleteAllModels()
            try LocalDataManager.shared.deleteAllData()
        } catch {
            deleteAllError = error.localizedDescription
            return
        }

        let client = llmService.bigBroClient
        client.disableAutoReconnect()
        client.disconnect()
        client.forgetAllDevices()

        // Reload the form from the freshly recreated defaults. `hasLoaded` off first, so the
        // reload's own writes to the fields aren't saved back as if the user had made them.
        hasLoaded = false
        loadPreferences()
        refreshModelSizes()
    }

    // MARK: - Profile export and import

    private func exportProfile() {
        profileMessage = nil
        do {
            let backup = try LocalDataManager.shared.exportProfile(onDeviceModel: llmService.preferredOnDeviceModel)
            exportDocument = ProfileBackupDocument(data: try backup.encoded())
        } catch {
            profileMessage = ("Couldn't export your profile: \(error.localizedDescription)", true)
        }
    }

    /// Reads the chosen file and asks before importing it.
    private func readProfile(_ result: Result<URL, Error>) {
        profileMessage = nil
        do {
            let url = try result.get()
            // A file from Files or iCloud Drive is outside the sandbox until asked for.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            pendingImport = try ProfileBackup.decode(Data(contentsOf: url))
        } catch {
            profileMessage = (error.localizedDescription, true)
        }
    }

    private func importDescription(_ backup: ProfileBackup) -> String {
        let exported = backup.exportedAt.formatted(date: .abbreviated, time: .shortened)
        return "Exported \(exported): \(backup.recipes.count) recipes, \(backup.pantry.count) inventory items and \(backup.shoppingList.count) on the shopping list. They're added to what's on this device, and your settings are replaced by the profile's."
    }

    private func importProfile(_ backup: ProfileBackup) {
        pendingImport = nil
        do {
            let summary = try LocalDataManager.shared.importProfile(backup)
            // Only a model this device can run; otherwise it keeps its own choice.
            if let model = backup.settings.onDeviceModel, LLMService.onDeviceModelOptions.contains(model) {
                llmService.preferredOnDeviceModel = model
            }
            // Reload the form from the imported settings, without saving the reload back.
            hasLoaded = false
            loadPreferences()
            if let voiceSettings = try? LocalDataManager.shared.fetchPreferences().toUserPreferences().voiceSettings {
                voiceAssistant.updateVoiceSettings(voiceSettings)
            }
            profileMessage = (summary.message, false)
        } catch {
            profileMessage = ("Couldn't import the profile: \(error.localizedDescription)", true)
        }
    }

    private func saveIfLoaded() {
        guard hasLoaded else { return }
        savePreferences()
    }

    private func loadPreferences() {
        do {
            let prefs = try LocalDataManager.shared.fetchPreferences().toUserPreferences()
            // Restore what was saved, rather than resetting to `.local` on every appearance.
            // Forcing the default here meant a user who chose BigBro was switched back to
            // on-device inference the next time they opened Settings, silently and without the
            // picker appearing to change.
            //
            // A device with no on-device model can only be `.bigBro`, whatever is stored.
            let provider: LLMProvider = LLMService.deviceSupportsLocalModels ? prefs.llmProvider : .bigBro
            llmProvider = provider
            speechRate = prefs.voiceSettings.speechRate
            voiceIdentifier = AVSpeechSynthesisVoice.isAutomatic(prefs.voiceSettings.voiceIdentifier)
                ? AVSpeechSynthesisVoice.automaticIdentifier : prefs.voiceSettings.voiceIdentifier
            autoSpeakResponses = prefs.voiceSettings.autoSpeakResponses
            bigBroVoice = prefs.voiceSettings.bigBroVoice
            llmService.currentProvider = provider
            hasLoaded = true
        } catch {
            dprint("Failed to load preferences: \(error)")
        }
    }

    private func savePreferences() {
        let voiceSettings = LocalVoiceSettings(
            speechRate: speechRate,
            voiceIdentifier: voiceIdentifier,
            autoSpeakResponses: autoSpeakResponses,
            wakePhrase: LocalVoiceSettings.wakePhrase,
            bigBroVoice: bigBroVoice
        )
        // Pushed straight to the assistant as well as saved. A cooking session only reads the
        // stored settings when it starts, so without this an edit would wait for the next cook.
        voiceAssistant.updateVoiceSettings(voiceSettings)

        do {
            try LocalDataManager.shared.updatePreferences(voiceSettings: voiceSettings, llmProvider: llmProvider)
        } catch {
            dprint("Failed to save preferences: \(error)")
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
                    Text(Self.label(for: voice)).tag(voice)
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

    /// "af_heart" → "Heart (female)": Kokoro's ids put the accent and voice in a prefix.
    private static func label(for id: String) -> String {
        let parts = id.split(separator: "_", maxSplits: 1)
        guard parts.count == 2 else { return id }
        let kind = parts[0].hasSuffix("f") ? "female" : parts[0].hasSuffix("m") ? "male" : nil
        let name = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        return kind.map { "\(name) (\($0))" } ?? name
    }

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

/// A profile file for the save sheet: the JSON ``ProfileBackup/encoded()`` makes.
struct ProfileBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
