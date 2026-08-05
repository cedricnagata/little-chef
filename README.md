# LittleChef

A hands-free iOS cooking assistant powered by on-device LLM inference and voice interaction. Transform any recipe into an interactive cooking companion that provides intelligent assistance while your hands are busy.

Available on [TestFlight](https://testflight.apple.com/join/Rz11FzNk)

## Features

### Voice-First Cooking
- Hands-free interaction — no need to touch the device while cooking
- Ask natural language questions: "How long do I cook this?" or "Can I substitute butter with oil?"
- Two hands-free modes, chosen when you start the loop:
  - **Hands-free** — answers everything it hears, for cooking alone
  - **Wait for "hey little chef"** — only answers when called by name, for a busy kitchen. The wake word is editable in Settings
- Push-to-talk dictation as an alternative: one utterance lands in the text field, where a misheard ingredient can be corrected before it becomes a question
- Auto-speak responses, with the voice matched to the active AI backend

### AI Cooking Assistant
- Contextual conversation tied to your current recipe and cooking session
- Intelligent timer suggestions based on recipe steps
- On-device inference keeps everything private — no data leaves your phone

### Recipe Import
- **URLs**: Parse recipes from any cooking website
- **Images**: Extract recipes from photos of cookbooks or handwritten cards via OCR
- **Text**: Paste or type any recipe and have it structured automatically

### Timer Management
- Set multiple timers via voice or text
- Native iOS notifications when timers complete
- Context-aware — the assistant knows which step each timer belongs to

## AI Inference

LittleChef supports two inference backends, selectable in Settings. The choice is pinned when a cooking session starts and holds for that whole session, so an answer never changes backend halfway through a recipe.

### On-Device (Local)
Runs a [PrismML Bonsai](https://huggingface.co/prism-ml) 1-bit model directly on iPhone using [MLX](https://github.com/ml-explore/mlx-swift). Which model depends on how much RAM the device has:

| RAM | Model | Capability |
| --- | --- | --- |
| 6 GB+ (iPhone 16 Pro or later) | [Bonsai 8B](https://huggingface.co/prism-ml/Bonsai-8B-mlx-1bit) (~3.5 GB) | Recipe parsing, cooking assistant, timer tools |
| 4 GB+ | [Bonsai 4B](https://huggingface.co/prism-ml/Bonsai-4B-mlx-1bit) (~1.8 GB) | Cooking assistant only |
| 3 GB+ | [Bonsai 1.7B](https://huggingface.co/prism-ml/Bonsai-1.7B-mlx-1bit) (~0.9 GB) | Cooking assistant only |
| Under 3 GB | — | BigBro only |

Only the 8B model supports tool use. Below it, recipe import still works from recipe websites via structured data, and timers are set manually.

- No internet required after initial model download
- Full privacy — all inference runs on-device
- ~44 tok/s generation on iPhone 16 Pro Max

### BigBro (Mac Companion)
Pairs with a Mac running the BigBro companion app over local network. The Mac runs `gpt-oss-20b` in-process through MLX and handles all inference, with tool use fully supported. Suitable for older devices that don't meet the RAM requirement.

- No model download on iPhone
- Full tool support (timers, recipe modifications)
- Requires a paired Mac on the same network

## Speech

Both halves of the voice loop — transcription and synthesis — follow whichever AI backend the session is using. There is no separate speech setting to keep in sync.

| | On-Device | BigBro |
| --- | --- | --- |
| Transcription | Apple's on-device `SFSpeechRecognizer` | Parakeet on the Mac |
| Synthesis | `AVSpeechSynthesizer`, any installed system voice, adjustable rate | Kokoro on the Mac, 20 named American English voices |

Settings shows only the controls that apply to the active backend. If the Mac drops mid-cook, spoken replies fall back to the on-device voice rather than going silent.

Turn-taking is the same on both paths: the microphone endpoints on signal energy — with a preroll so the opening consonant survives — rather than on a fixed silence timer, and wake-word matching is fuzzy enough to survive a mishearing of the phrase.

## Architecture

```
┌──────────────────────────────────────────────┐
│               iOS App (SwiftUI)              │
│                                              │
│  RecipeListView → RecipeDetailView           │
│         ↓                                    │
│  CookingSessionView                          │
│         ↓                                    │
│  VoiceAssistant                              │
│  ├── LocalVoiceSession   (on-device loop)    │
│  └── BigBroVoiceSession  (Mac loop)          │
│         ↓                                    │
│  LocalCookingAgent                           │
│         ↓                                    │
│  LLMService                                  │
│  ├── Local: Bonsai via MLX                   │
│  └── BigBro: Mac companion via network       │
└──────────────────────────────────────────────┘
```

**Key components:**
- `LLMService` — manages inference backend selection, model download/loading, and chat completions
- `LocalCookingAgent` — maintains conversation history and builds prompts for the cooking session
- `LocalRecipeParser` — parses recipes from URLs (schema.org + LLM cleanup), images (OCR), and text
- `VoiceAssistant` — the voice front end; owns permissions, the shared `VoicePhase` state the UI renders, and which of the two sessions below is running
- `LocalVoiceSession` — the on-device hands-free loop: listen, transcribe, answer, speak, repeat, with no Mac in the loop. Mirrors `BigBroVoiceSession` in BigBroKit, which does the same on the Mac path
- `OnDeviceSpeaker` — `AVSpeechSynthesizer` wrapped so an utterance can be awaited, and so a cancelled one exits the same way a finished one does
- `BigBroClient` (BigBroKit) — handles pairing, connection, and streaming chat with the Mac companion
- `TimerManager` — manages multiple concurrent cooking timers with iOS notifications
- `LocalDataManager` — SwiftData persistence for recipes and user preferences, with optional iCloud sync

## Tech Stack

- **UI**: SwiftUI, AVFoundation (TTS), Speech Framework (STT)
- **On-device inference**: MLX Swift, PrismML Bonsai 1-bit (8B / 4B / 1.7B by device RAM)
- **Mac inference & speech**: BigBroKit (local network pairing, Parakeet STT, Kokoro TTS)
- **Recipe parsing**: WebScraperService, OCRService, schema.org extraction
- **Storage**: SwiftData (CloudKit-backed, falling back to a local-only store)
