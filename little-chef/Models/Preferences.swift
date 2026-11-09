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

/// The on-device models the app can run: PrismML's Bonsai 2 family, ternary weights packed as
/// MLX 2-bit in a Hadamard-rotated basis (`prism_hadamard_qwen35`). Loading them needs the
/// mlx-swift-lm fork described in CLAUDE.md, "MLX packages".
enum CookingModelChoice: String, Codable, CaseIterable {
    case bonsai2_27B = "bonsai2_27b"
    case bonsai2_9B = "bonsai2_9b"
    case bonsai2_4B = "bonsai2_4b"
    case bonsai2_2B = "bonsai2_2b"

    var displayName: String {
        switch self {
        case .bonsai2_27B: return "Bonsai 2 27B"
        case .bonsai2_9B: return "Bonsai 2 9B"
        case .bonsai2_4B: return "Bonsai 2 4B"
        case .bonsai2_2B: return "Bonsai 2 2B"
        }
    }

    /// The Hugging Face repository the weights come from.
    var modelId: String {
        switch self {
        case .bonsai2_27B: return "prism-ml/Ternary-Bonsai-2-27B-mlx-2bit"
        case .bonsai2_9B: return "prism-ml/Ternary-Bonsai-2-9B-mlx-2bit"
        case .bonsai2_4B: return "prism-ml/Ternary-Bonsai-2-4B-mlx-2bit"
        case .bonsai2_2B: return "prism-ml/Ternary-Bonsai-2-2B-mlx-2bit"
        }
    }

    /// The download. Every pack includes a vision tower the app never loads (it is in the same
    /// file as the language weights), so this is more than ``memoryNeeded``.
    var approximateSize: String {
        switch self {
        case .bonsai2_27B: return "~8.6 GB"
        case .bonsai2_9B: return "~3.6 GB"
        case .bonsai2_4B: return "~2.0 GB"
        case .bonsai2_2B: return "~1.2 GB"
        }
    }

    /// The app memory limit, in GiB, a device needs to run this model: the language weights,
    /// an 8k-token context and MLX's working memory, plus about half a GiB for the rest of the
    /// app (speech, audio, UI). Weights: 27B 7.15, 9B 2.37, 4B 1.12, 2B 0.50 GiB. Only a quarter
    /// of the layers keep a per-token cache, so the context costs 0.1 to 0.5 GiB.
    var memoryNeeded: Double {
        switch self {
        case .bonsai2_27B: return 8.75
        case .bonsai2_9B: return 3.5
        case .bonsai2_4B: return 2.25
        case .bonsai2_2B: return 1.5
        }
    }

    /// Whether this model supports the full feature set: recipe parsing and the timer and
    /// recipe tools. The smaller models run cooking chat only.
    var isFullCapability: Bool {
        self == .bonsai2_27B || self == .bonsai2_9B
    }

    /// Chat-template variables this model needs on every request.
    ///
    /// Bonsai 2 is Qwen3.5 underneath, whose template thinks by default — PrismML notes even
    /// simple prompts can use 3,000 thinking tokens. On a phone that is minutes of reasoning
    /// before the first word of an answer, so thinking is off for every model.
    var templateContext: [String: any Sendable]? {
        ["enable_thinking": false]
    }

    init?(modelId: String) {
        guard let match = Self.allCases.first(where: { $0.modelId == modelId }) else { return nil }
        self = match
    }

    /// A stored choice, including the first family's names, which builds up to 63 saved in
    /// `UserDefaults` and in exported profiles. Each maps to its Bonsai 2 successor.
    init?(storedValue: String) {
        if let choice = Self(rawValue: storedValue) {
            self = choice
            return
        }
        switch storedValue {
        case "bonsai27b_ternary": self = .bonsai2_27B
        case "bonsai8b": self = .bonsai2_9B
        case "bonsai4b": self = .bonsai2_4B
        case "bonsai1_7b": self = .bonsai2_2B
        default: return nil
        }
    }

    /// The first Bonsai family's repositories. Nothing loads them any more; a download of one
    /// is gigabytes the app removes at launch.
    static let retiredModelIds = [
        "prism-ml/Ternary-Bonsai-27B-mlx-2bit",
        "prism-ml/Bonsai-8B-mlx-1bit",
        "prism-ml/Bonsai-4B-mlx-1bit",
        "prism-ml/Bonsai-1.7B-mlx-1bit",
    ]
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
