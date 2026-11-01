//
//  Preferences.swift
//  little-chef
//
//  The settings the app runs on, as plain values. `UserPreferencesEntity` is how they are
//  stored and synced; these are what everything else reads.
//

import Foundation

/// Which backend answers: the on-device model or a paired BigBro Mac.
enum LLMProvider: String, Codable, CaseIterable {
    case local = "local"
    case bigBro = "bigbro"

    var displayName: String {
        switch self {
        case .local: return "On-Device"
        case .bigBro: return "BigBro"
        }
    }
}

/// The on-device models the app can run.
enum CookingModelChoice: String, Codable, CaseIterable {
    case bonsai27BTernary = "bonsai27b_ternary"
    case bonsai8B = "bonsai8b"
    case bonsai4B = "bonsai4b"
    case bonsai1_7B = "bonsai1_7b"

    var displayName: String {
        switch self {
        case .bonsai27BTernary: return "Bonsai 27B (ternary)"
        case .bonsai8B: return "Bonsai 8B (1-bit)"
        case .bonsai4B: return "Bonsai 4B (1-bit)"
        case .bonsai1_7B: return "Bonsai 1.7B (1-bit)"
        }
    }

    /// The Hugging Face repository the weights come from.
    var modelId: String {
        switch self {
        case .bonsai27BTernary: return "prism-ml/Ternary-Bonsai-27B-mlx-2bit"
        case .bonsai8B: return "prism-ml/Bonsai-8B-mlx-1bit"
        case .bonsai4B: return "prism-ml/Bonsai-4B-mlx-1bit"
        case .bonsai1_7B: return "prism-ml/Bonsai-1.7B-mlx-1bit"
        }
    }

    var approximateSize: String {
        switch self {
        case .bonsai27BTernary: return "~7 GB"
        case .bonsai8B: return "~3.5 GB"
        case .bonsai4B: return "~1.8 GB"
        case .bonsai1_7B: return "~0.9 GB"
        }
    }

    /// Whether this model supports the full feature set: recipe parsing and the timer and
    /// recipe tools. The smaller models run cooking chat only.
    var isFullCapability: Bool {
        self == .bonsai27BTernary || self == .bonsai8B
    }

    /// Chat-template variables this model needs on every request.
    ///
    /// The 27B is Qwen3.6 underneath, whose template thinks by default. On a phone that is
    /// hundreds of tokens of reasoning at a few tokens a second before the first word of an
    /// answer, out of a 2048-token budget — a cook asking how long to rest the meat would wait
    /// most of a minute.
    var templateContext: [String: any Sendable]? {
        switch self {
        case .bonsai27BTernary: return ["enable_thinking": false]
        case .bonsai8B, .bonsai4B, .bonsai1_7B: return nil
        }
    }

    init?(modelId: String) {
        guard let match = Self.allCases.first(where: { $0.modelId == modelId }) else { return nil }
        self = match
    }
}

/// How the assistant speaks and listens.
struct LocalVoiceSettings: Codable, Equatable {
    /// Absolute `AVSpeechUtterance.rate` on its 0.0–1.0 scale, where 0.5
    /// (`AVSpeechUtteranceDefaultSpeechRate`) is normal speed — not a multiplier. Settings
    /// displays it as a multiple of normal, so a stored 0.5 shows as "1.0x".
    var speechRate: Float
    var voiceIdentifier: String
    var autoSpeakResponses: Bool
    /// What the assistant answers to in wake-word hands-free mode. Free text, because the
    /// whole point is that it is the user's name for it — but a phrase too short to gate on is
    /// refused by `WakeWord` rather than silently matching nothing.
    var wakePhrase: String = "hey little chef"
    /// Kokoro voice id for the Mac's synthesizer. Separate from `voiceIdentifier`, which names
    /// an `AVSpeechSynthesisVoice` — the two backends share no vocabulary of voices.
    var bigBroVoice: String = "af_heart"

    static let defaultSettings = LocalVoiceSettings(
        speechRate: 0.5,
        voiceIdentifier: "com.apple.ttsbundle.Samantha-compact",
        autoSpeakResponses: true
    )
}

/// The stored preferences that something reads.
struct LocalUserPreferences: Codable {
    let voiceSettings: LocalVoiceSettings
    let llmProvider: LLMProvider
}
