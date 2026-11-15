//
//  VoiceProcessing.swift
//  little-chef
//
//  Apple's noise suppression and echo cancellation on the microphone, and the one recorder
//  push-to-talk uses to get it.
//

import Foundation
import AVFoundation

/// Turns on the system's voice processing for an engine's microphone.
///
/// This is the noise filtering: Apple's voice processing I/O unit suppresses steady background
/// noise (a range hood, a running tap, the dishwasher), cancels echo and evens out the level, on
/// the device. It is also what makes iOS offer its microphone modes for the app, Voice Isolation
/// among them, in Control Center or through ``MicrophoneMode/showPicker()``.
///
/// Every place the app opens the microphone goes through an engine with this on: the Mac path in
/// `BigBroVoiceSession` (which does it itself), hands-free on the device in `LocalVoiceSession`,
/// and push-to-talk in ``FilteredRecorder``.
enum VoiceProcessing {

    /// Enables voice processing on `engine`. Call before the engine starts; reconfiguring the
    /// unit stops a running engine.
    ///
    /// Returns false when the device refuses, which is not fatal: capture still works, unfiltered,
    /// as it did before this existed.
    @discardableResult
    static func enable(on engine: AVAudioEngine) -> Bool {
        // The input and output are one I/O unit under voice processing, and it renders only when
        // the output has something connected. Touching the main mixer connects it to the output,
        // so an engine that only records still runs, playing silence.
        _ = engine.mainMixerNode
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
        } catch {
            dprint("🎤 voice processing unavailable: \(error.localizedDescription)")
            return false
        }
        // Voice processing ducks every other sound on the device while it runs, by default hard
        // enough to make a podcast in the kitchen inaudible. The least ducking the system allows
        // keeps it audible; the app's own speech never plays while the engine runs.
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
        return true
    }
}

/// iOS's microphone modes: Standard, Voice Isolation, Wide Spectrum.
///
/// The user picks the mode, not the app; Apple offers no way to set it, only to show its picker.
/// iOS remembers the choice per app. It applies only while voice processing is running, so the
/// picker is offered while the microphone is open.
enum MicrophoneMode {

    /// The mode in use, for a label. Nil before iOS reports one.
    static var current: String? {
        switch AVCaptureDevice.activeMicrophoneMode {
        case .standard: return "Standard"
        case .voiceIsolation: return "Voice Isolation"
        case .wideSpectrum: return "Wide Spectrum"
        @unknown default: return nil
        }
    }

    /// Opens the system's microphone mode picker.
    static func showPicker() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }
}

/// Records the microphone to a 16 kHz mono WAV, through voice processing.
///
/// Push-to-talk used `AVAudioRecorder`, which has no way to turn voice processing on, so a
/// question asked over a running range hood was transcribed with the hood in it. This is the same
/// job on an engine that filters.
///
/// The file format is fixed whatever the microphone is: AirPods connecting mid-recording swap a
/// 48 kHz input for a 16 kHz one, and only the converter in front of the file is rebuilt.
@MainActor
final class FilteredRecorder {

    enum RecorderError: LocalizedError {
        case formatUnavailable
        var errorDescription: String? { "The microphone isn't available right now." }
    }

    static let sampleRate: Double = 16_000

    let url: URL
    private let engine = AVAudioEngine()
    private let writer: Writer
    private var configurationObserver: NSObjectProtocol?

    /// Opens the file and starts recording into it.
    init(url: URL) throws {
        self.url = url
        guard let processing = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false
        ) else { throw RecorderError.formatUnavailable }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        writer = Writer(file: file, format: processing)

        VoiceProcessing.enable(on: engine)
        try attachTap()
        observeConfigurationChanges()
    }

    /// Stops recording and closes the file. Safe to call more than once.
    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        writer.close()
    }

    private func attachTap() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: writer.format) else {
            throw RecorderError.formatUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat,
                         block: Self.tapBlock(writer: writer, converter: converter))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// Built outside the main actor: the tap runs on an audio thread, and a closure formed in
    /// a main-actor method would be taken as main-actor isolated.
    nonisolated private static func tapBlock(writer: Writer, converter: AVAudioConverter) -> AVAudioNodeTapBlock {
        { buffer, _ in writer.write(buffer, using: converter) }
    }

    /// Reattaches after the input changes under the recording (a headset, or voice processing
    /// itself reconfiguring the unit), which stops the engine.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.configurationObserver != nil else { return }
                self.engine.inputNode.removeTap(onBus: 0)
                // A recording that can't restart keeps what it has; stopping it is the user's
                // next tap either way.
                try? self.attachTap()
            }
        }
    }

    /// The file, written from the tap's thread and closed from the main actor.
    private final class Writer: @unchecked Sendable {
        let format: AVAudioFormat
        private var file: AVAudioFile?
        private let lock = NSLock()

        init(file: AVAudioFile, format: AVAudioFormat) {
            self.file = file
            self.format = format
        }

        func write(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, output.frameLength > 0 else { return }
            lock.lock()
            defer { lock.unlock() }
            try? file?.write(from: output)
        }

        /// Releasing the file is what finishes its header.
        func close() {
            lock.lock()
            defer { lock.unlock() }
            file = nil
        }
    }
}
