//
//  KokoroVoice.swift
//  little-chef
//
//  Kokoro on the iPhone, through Core ML (FluidAudio): the voice the Mac speaks with, without the
//  Mac. Offered only where memory allows; see the Apple bug below.
//

import Foundation
import AVFoundation
import FluidAudio
import UIKit
import os

/// The on-device Kokoro voice: its download, loading it for a cook, and speaking a sentence.
///
/// **Why it is opt-in.** FluidAudio, the package that runs Kokoro on Core ML, knows of no safe way
/// to run it on iOS 27, and iOS 26.4–26.6 have the same kind of bug: synthesis can crash inside
/// Apple's libBNNS (minutes to an hour in), in a way no app can catch (FluidAudio #889, #844,
/// checked 2026-11-15). Cedric chose to try it anyway. So a marker file is written before every
/// synthesis and removed after it: one still there at launch means the app died mid-synthesis,
/// and Kokoro switches itself off and says so in Settings.
///
/// **Memory.** About 170 MB loaded, by FluidAudio's figures, not yet measured here. It runs on the
/// CPU and the Neural Engine (`.aneTailCpu`), never the GPU, which the 9B is using to answer. It
/// loads only behind a cook's getting-ready screen and only with room to spare, unloads when
/// the cook ends or memory runs short, and every load and synthesis is logged with the footprint
/// (`llm-timing`), for measuring on a phone.
@MainActor
final class KokoroVoice: ObservableObject {
    static let shared = KokoroVoice()

    /// Kokoro voices to offer: American English only, as the Mac's picker offers.
    static let voices = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole",
        "af_nova", "af_river", "af_sarah", "af_sky", "am_adam", "am_echo", "am_eric",
        "am_fenrir", "am_liam", "am_michael", "am_onyx", "am_puck", "am_santa",
    ]

    /// "af_heart" → "Heart (female)": Kokoro's ids put the accent and voice in a prefix.
    static func label(for id: String) -> String {
        let parts = id.split(separator: "_", maxSplits: 1)
        guard parts.count == 2 else { return id }
        let kind = parts[0].hasSuffix("f") ? "female" : parts[0].hasSuffix("m") ? "male" : nil
        let name = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        return kind.map { "\(name) (\($0))" } ?? name
    }

    /// The user's switch in Settings, per device like the model choice. Until they touch it: on
    /// where the device has room for Kokoro beside its model (``LLMService/fitsKokoro(alongside:)``),
    /// off elsewhere.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    @Published private(set) var isDownloaded: Bool
    @Published private(set) var isDownloading = false
    /// How far the download is, 0–1, while ``isDownloading``.
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var isLoaded = false
    /// Loading now: what plays a sample waits on, and says so.
    @Published private(set) var isLoading = false
    /// The last download or load failure, for Settings.
    @Published private(set) var error: String?
    /// The app died while Kokoro was synthesizing, last time: it has been switched off.
    @Published private(set) var crashedLastTime = false

    /// What loading it needs free on top of everything else. The Simulator measured it at 60–85 MB
    /// loaded and the whole app at about 145 MB while it spoke (2026-11-15); 350 MB until then.
    private static let memoryNeeded: UInt64 = 250 * 1024 * 1024
    /// The room a device's memory limit must have for Kokoro beside its model to offer it at all.
    /// 0.2 GiB puts the iPhone 14 Pro (a 4.0 GiB limit, the 9B budgeted at 3.75) just inside; it
    /// was 0.35 GiB, which left it out, until Cedric asked for it there (2026-11-15).
    static let fitMarginGiB = 0.2
    /// A memory warning with less than this left unloads it, and replies go back to Apple's voice.
    private static let memoryWarningUnloadHeadroom: UInt64 = 512 * 1024 * 1024

    /// What the English download comes to on disk: 183 MB in the Simulator (2026-11-15).
    static let expectedDownloadBytes: Int64 = 183_000_000

    private static let enabledKey = "little-chef.kokoro-enabled"
    private static let downloadedKey = "little-chef.kokoro-downloaded"
    private static let log = Logger(subsystem: "NagataInc.little-chef", category: "llm-timing")

    static let directory: URL = {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kokoro-voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    /// Written before each synthesis and removed after: still there at launch means a crash.
    private static var crashMarker: URL { directory.appendingPathComponent("speaking") }

    private var manager: KokoroAneManager?

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? Self.enabledByDefault
        isDownloaded = UserDefaults.standard.bool(forKey: Self.downloadedKey)
        if FileManager.default.fileExists(atPath: Self.crashMarker.path) {
            try? FileManager.default.removeItem(at: Self.crashMarker)
            crashedLastTime = true
            // Saved by hand: `didSet` doesn't run in `init`, and the default would switch it back on.
            isEnabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            Self.log.error("kokoro: the app ended during a synthesis last time; switched off")
        }
        // Never removed: a process-lifetime singleton.
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLoaded else { return }
                let available = UInt64(os_proc_available_memory())
                guard available > 0, available < Self.memoryWarningUnloadHeadroom else { return }
                Self.log.notice("kokoro: memory warning with \(available >> 20, privacy: .public) MB left; unloading")
                await self.unload()
            }
        }
    }

    /// Whether replies should be spoken with Kokoro: switched on, and loaded.
    var isReady: Bool { isOffered && isEnabled && isLoaded }

    /// Whether this device is offered Kokoro at all: only where the memory limit has room for it
    /// beside the model the device runs (Cedric, 2026-11-15: not shown where it doesn't fit).
    /// Always in Debug, which reports the 9B everywhere too, so the Simulator can exercise it.
    static let isOffered: Bool = {
        #if DEBUG
        return true
        #else
        return LLMService.supportedOnDeviceModel.map(LLMService.fitsKokoro(alongside:)) ?? false
        #endif
    }()

    var isOffered: Bool { Self.isOffered }

    // MARK: - Download

    /// Fetches the English Core ML stages and voice data (a few hundred MB), loading and unloading
    /// them once, which is also what compiles them for this device.
    ///
    /// FluidAudio reports no progress for this download, so the bar is the bytes on disk against
    /// the measured total, sampled twice a second, held under 100% until it has finished.
    func download() async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        error = nil
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                let fraction = Double(Self.bytesOnDisk()) / Double(Self.expectedDownloadBytes)
                self.downloadProgress = min(max(fraction, self.downloadProgress), 0.99)
            }
        }
        defer {
            watcher.cancel()
            isDownloading = false
            downloadProgress = 0
        }
        do {
            let manager = Self.makeManager()
            try await manager.initialize(preloadVoices: [Self.voices[3]])
            await manager.cleanup()
            isDownloaded = true
            UserDefaults.standard.set(true, forKey: Self.downloadedKey)
            Self.log.notice("kokoro: downloaded")
        } catch {
            self.error = "Couldn't download the Kokoro voice: \(error.localizedDescription)"
        }
    }

    /// Removes every Kokoro file. Delete All Data calls it too.
    func deleteFiles() async {
        await unload()
        for item in (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: item)
        }
        isDownloaded = false
        UserDefaults.standard.removeObject(forKey: Self.downloadedKey)
    }

    /// Back to how a new install starts: the default switch, nothing downloaded, no crash note.
    func reset() async {
        await deleteFiles()
        isEnabled = Self.enabledByDefault
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        crashedLastTime = false
        error = nil
    }

    /// Kokoro is the default wherever it is offered.
    private static var enabledByDefault: Bool { isOffered }

    // MARK: - Loading

    /// Loads it, if it is switched on, downloaded and there is room. Never downloads: a voice that
    /// isn't on the device just means Apple's voice. A failure is reported in Settings and the
    /// cook carries on with Apple's voice.
    func loadIfWanted() async {
        guard isOffered, isEnabled, isDownloaded, !isLoaded else { return }
        let available = UInt64(os_proc_available_memory())
        if available > 0, available < Self.memoryNeeded {
            Self.log.notice("kokoro: not loaded, \(available >> 20, privacy: .public) MB available")
            return
        }
        let started = Date()
        isLoading = true
        defer { isLoading = false }
        do {
            let manager = Self.makeManager()
            try await manager.initialize()
            self.manager = manager
            isLoaded = true
            Self.log.notice("kokoro: loaded in \(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public)s, footprint \(Self.footprintMB, privacy: .public) MB, available \(UInt64(os_proc_available_memory()) >> 20, privacy: .public) MB")
        } catch {
            self.error = "Couldn't load the Kokoro voice: \(error.localizedDescription)"
            Self.log.error("kokoro: load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func unload() async {
        guard let manager else { return }
        self.manager = nil
        isLoaded = false
        await manager.cleanup()
        Self.log.notice("kokoro: unloaded, footprint \(Self.footprintMB, privacy: .public) MB")
    }

    // MARK: - Speaking

    /// One sentence as WAV, or nil to fall back to Apple's voice. `speed`: 1 is normal.
    func synthesize(_ text: String, voice: String, speed: Float) async -> Data? {
        guard isReady, let manager else { return nil }
        let voice = Self.voices.contains(voice) ? voice : "af_heart"
        let started = Date()
        FileManager.default.createFile(atPath: Self.crashMarker.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: Self.crashMarker) }
        do {
            let wav = try await manager.synthesize(text: text, voice: voice, speed: min(max(speed, 0.5), 2))
            Self.log.notice("kokoro: \(text.count, privacy: .public) chars in \(Date().timeIntervalSince(started), format: .fixed(precision: 2), privacy: .public)s, footprint \(Self.footprintMB, privacy: .public) MB")
            return wav
        } catch {
            Self.log.error("kokoro: synthesis failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Helpers

    /// What Kokoro's files take on disk, or nil when it isn't downloaded.
    var downloadedBytes: Int64? {
        isDownloaded ? Self.bytesOnDisk() : nil
    }

    private static func bytesOnDisk() -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// The CPU and Neural Engine route on every OS: on iOS 26 FluidAudio's default would put two
    /// stages on the GPU, which the 9B is using to answer.
    private static func makeManager() -> KokoroAneManager {
        KokoroAneManager(directory: directory, computeUnits: .aneTailCpu, version: .v3)
    }

    private static var footprintMB: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint >> 20 : 0
    }
}
