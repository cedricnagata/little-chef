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
- Auto-speak responses, with the voice matched to the active AI backend. Replies are spoken sentence by sentence as they generate, rather than after the whole answer

### AI Cooking Assistant
- Contextual conversation tied to your current recipe and cooking session
- Knows the recipe, the servings you're cooking for, and every timer with how long it has left
- With on-device inference nothing leaves your phone; with BigBro it stays on your local network

### Changing the Recipe as You Cook
- Ask the assistant to change the recipe mid-cook: add or remove ingredients, rewrite steps, change the title, times or servings
- Nothing is saved until you finish. Ending the cook shows what changed, and you choose whether to keep it
- **Cook Without a Recipe** starts from a blank page: tell the assistant what you're using and doing, and it writes the recipe down for you to save at the end
- Change the servings and every ingredient amount rescales, mixed numbers and fractions included

### Recipe Import
- **URLs**: Parse recipes from any cooking website
- **Images**: Extract recipes from photos of cookbooks or handwritten cards via OCR
- **Text**: Paste or type any recipe and have it structured automatically
- Every import opens for review before it's saved

### Kitchen: Inventory and Shopping List
- Keep a list of the ingredients you have, with a Staples section (salt, oil, flour…) that counts as always on hand
- A shopping list: add items by hand or a recipe's missing ingredients in one tap, then tick them off and move them into the inventory with **Done Shopping**
- Recipes show what you have and what's missing, and you're warned before starting a cook that needs something you don't have
- Filter recipes to those you **Can Make Now** or are **Missing a Few** (one or two) ingredients for
- **Suggested** ranks your recipes with AI for the time of day (breakfast, lunch, dinner or late night) and what's in your kitchen, with a non-AI fallback

### Timer Management
- Set multiple timers by voice, by text, or by hand
- The assistant creates a timer and waits for you to say go, so a misheard duration can be fixed before it starts
- Live Activities on the Lock Screen and Dynamic Island, and a notification when a timer finishes

### Your Data
- Recipes, preferences, inventory and shopping list stay on the device; nothing is synced or uploaded
- **Settings → Export Profile** saves all of it to one file, and **Import Profile** adds a file's contents back, on a new device or after reinstalling
- **Settings → Delete All Data** removes all of it, along with downloaded models and paired Macs
- No accounts, analytics or tracking. See the [privacy policy](docs/privacy.md)

## AI Inference

LittleChef supports two inference backends, selectable in Settings. The choice is pinned when a cooking session starts and holds for that whole session, so an answer never changes backend halfway through a recipe.

### On-Device (Local)
Runs a [PrismML Bonsai 2](https://prismml.com/news/bonsai-2-family) model directly on iPhone using [MLX](https://github.com/ml-explore/mlx-swift): Qwen3.5-based, with ternary weights packed as 2-bit. Which model depends on the app's memory limit, which iOS sets per device (well below the RAM fitted, raised by the increased-memory-limit entitlement):

| App memory limit | Model | Download | Capability |
| --- | --- | --- | --- |
| 3.5 GiB+ | [Bonsai 2 9B](https://huggingface.co/prism-ml/Ternary-Bonsai-2-9B-mlx-2bit) | ~3.6 GB | Recipe parsing, cooking assistant, timer and recipe tools |
| 2.25 GiB+ | [Bonsai 2 4B](https://huggingface.co/prism-ml/Ternary-Bonsai-2-4B-mlx-2bit) | ~2.0 GB | Cooking assistant only |
| 1.5 GiB+ | [Bonsai 2 2B](https://huggingface.co/prism-ml/Ternary-Bonsai-2-2B-mlx-2bit) | ~1.2 GB | Cooking assistant only |
| Less | — | — | BigBro only |

A device whose limit is 8.75 GiB or more (in practice an iPad with 16 GB) can also pick [Bonsai 2 27B](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-mlx-2bit) (~8.6 GB) in Settings, alongside its default model. Each threshold is the model's language weights, an 8k-token context and MLX's working memory, plus about 0.5 GiB for the rest of the app. The downloads are larger than that because every pack includes a vision tower the app never loads.

Only the 27B and 9B models support tool use. Below them, recipe import still works from recipe websites via structured data, and timers are set manually. Thinking is turned off on every model.

- Models are downloaded only when you tap Download in Settings, with the size shown and a warning on cellular
- No internet required after the download
- Full privacy — all inference runs on-device

### BigBro (Mac Companion)
Pairs with a Mac running [BigBro](https://github.com/cedricnagata/bigbro) over the local network. The Mac runs `bonsai-27b-ternary` (Bonsai 27B ternary) in-process through MLX and handles all inference, with tool use fully supported. Suitable for older devices that don't meet the RAM requirement.

- No model download on iPhone
- Full tool support (timers, recipe changes)
- Requires a paired Mac on the same network. Pairing is approved on the Mac, once per device

## Speech

Both halves of the voice loop — transcription and synthesis — follow whichever AI backend the session is using. There is no separate speech setting to keep in sync.

| | On-Device | BigBro |
| --- | --- | --- |
| Transcription | Apple's on-device `SFSpeechRecognizer` | Parakeet on the Mac |
| Synthesis | `AVSpeechSynthesizer`, any installed system voice, adjustable rate | Kokoro on the Mac, 20 named American English voices |

Settings shows only the controls that apply to the active backend. If the Mac drops mid-cook, spoken replies fall back to the on-device voice rather than going silent.

On-device transcription never falls back to Apple's servers. A device that can't recognize speech on-device has voice input turned off instead.

Turn-taking is the same on both paths: the microphone endpoints on signal energy — with a preroll so the opening consonant survives — rather than on a fixed silence timer, and wake-word matching is fuzzy enough to survive a mishearing of the phrase.

## Architecture

```
┌───────────────────────────────────────────────────────────────────────────┐
│                             iOS App (SwiftUI)                             │
│                                                                           │
│   Recipes        Kitchen         Cook                                     │
│      ↓              ↓              ↓                                      │
│   RecipeManager  KitchenManager  CookingSessionManager                    │
│      │              │            VoiceAssistant                           │
│      │              │            ├── LocalVoiceSession   (on-device loop) │
│      │              │            └── BigBroVoiceSession  (Mac loop)       │
│      │              │              ↓                                      │
│      │              │            LocalCookingAgent + CookingTools         │
│      │              ↓              ↓                                      │
│      │           LLMService  (chat, recipe import, Suggested)             │
│      │           ├── Local: Bonsai via MLX                                │
│      │           └── BigBro: Mac companion via network                    │
│      ↓                                                                    │
│   LocalDataManager  (SwiftData, on the device;                            │
│                      recipes, inventory, preferences)                     │
└───────────────────────────────────────────────────────────────────────────┘
```

**Key components:**
- `LLMService` — manages inference backend selection, model download/loading, and chat completions, streaming or not, on either backend
- `LocalCookingAgent` — builds the system prompt and tool list for the cooking session, and runs each turn from the session's transcript
- `CookingTools` (`ToolDefinition.swift`) — the timer and recipe tools, defined once for both backends
- `CookingSessionManager` — the cook in progress: its recipe, conversation and timers (`LocalTimer`, with notifications and Live Activities), and the assistant's edits, checked against the starting recipe by `RecipeDiff`
- `VoiceAssistant` — the voice front end; owns permissions, the shared `VoicePhase` state the UI renders, and which of the two sessions below is running
- `LocalVoiceSession` — the on-device hands-free loop: listen, transcribe, answer, speak, repeat, with no Mac in the loop. Mirrors `BigBroVoiceSession` in BigBroKit, which does the same on the Mac path
- `OnDeviceTranscriber` — Apple's speech recognizer, held to on-device recognition
- `OnDeviceSpeaker` — `AVSpeechSynthesizer` wrapped so an utterance can be awaited, and so a cancelled one exits the same way a finished one does
- `BigBroClient` (BigBroKit) — handles pairing, connection, and streaming chat with the Mac companion
- `RecipeManager` — the recipe list and every write to it
- `LocalRecipeParser` — imports recipes from URLs (`WebScraperService`, schema.org + LLM cleanup), images (`OCRService`), and text; the parsing itself is `RecipeExtraction`
- `KitchenManager` — the ingredient inventory and shopping list, what each recipe is missing (`IngredientMatcher`), and the Suggested ranking (`RecipeSuggester`)
- `IngredientScaler` — rescales ingredient amounts when the servings change
- `LocalDataManager` — SwiftData persistence for recipes, preferences, inventory and shopping list, on the device only, and profile export and import

## Tech Stack

- **UI**: SwiftUI, ActivityKit (Live Activities), AVFoundation (TTS), Speech Framework (STT)
- **On-device inference**: MLX Swift (`mlx-swift`, `mlx-swift-lm` from a fork, see below), PrismML Bonsai 2 (9B / 4B / 2B by the app's memory limit), Bonsai 2 27B where memory allows. Models come from Hugging Face through `swift-huggingface` and `swift-transformers`
- **Mac inference & speech**: [BigBroKit](https://github.com/cedricnagata/bigbro-kit) (local network pairing, Parakeet STT, Kokoro TTS)
- **Recipe parsing**: WebScraperService (`WKWebView`), OCRService (Vision), schema.org extraction
- **Storage**: SwiftData, on the device only, with Export Profile and Import Profile in Settings

## Building

- **Xcode 26** (the iOS 26 SDK). The app runs on iPhone and iPad with iOS 18.6 or later
- Open `little-chef.xcodeproj` and run the `little-chef` scheme. Swift packages resolve on first open
- **Debug** builds sign automatically with your development team. **Release** builds and archives sign manually and need the two App Store provisioning profiles installed (see CLAUDE.md, "Signing style")
- Debug builds always report the Bonsai 2 9B with full capability, whatever the device, so every feature can be tested on any phone. Release builds choose by the app's memory limit as in the table above

| Package | Requirement | Why |
| --- | --- | --- |
| [`mlx-swift`](https://github.com/ml-explore/mlx-swift) | exactly 0.33.0 | What the `mlx-swift-lm` revision below requires |
| [`mlx-swift-lm`](https://github.com/cedricnagata/mlx-swift-lm/tree/little-chef/bonsai-2) | pinned revision on a **temporary fork** | Upstream can't load Bonsai 2 until [ml-explore/mlx-swift-lm#630](https://github.com/ml-explore/mlx-swift-lm/pull/630) merges. See CLAUDE.md, "MLX packages", for how to go back |
| [`swift-huggingface`](https://github.com/huggingface/swift-huggingface) | 0.9.0+ | Model downloads |
| [`swift-transformers`](https://github.com/huggingface/swift-transformers) | 1.3.0+ | Tokenizers |
| [`bigbro-kit`](https://github.com/cedricnagata/bigbro-kit) | `main` branch | The BigBro Mac client |

## Project Layout

```
little-chef/
  Managers/    Long-lived state the views observe: recipes, kitchen, the cook, voice
  Models/      Recipes, the cooking session, timers, preferences, SwiftData entities
  Services/    Inference, persistence, import, and the pure logic the unit tests cover
  Views/       Recipes, Kitchen, Cooking and Settings screens
TimerWidget/   The Live Activity for running timers
little-chefTests/    Unit tests (Swift Testing)
little-chefUITests/  UI smoke tests
tools/linux-tests/   SwiftPM package that runs the unit tests without iOS
docs/privacy.md      The published privacy policy
```

## Tests

Unit tests live in `little-chefTests` and use Swift Testing. Run them in Xcode with ⌘U, or without a simulator:

```sh
swift test --package-path tools/linux-tests
```

That package links the app's Foundation-only files and the same test folder, so it runs anywhere Swift does. See CLAUDE.md, "Testing", for which files it covers and how to add one.

`little-chefUITests` holds UI smoke tests (launch, a URL import from start to finish, the Cook and Settings tabs). They need a simulator and run from Xcode only.

## Continuous Integration

| Workflow | Runs on | Does |
| --- | --- | --- |
| `unit-tests.yml` | every pull request and push to `main` | The unit tests on Linux |
| `pr-build.yml` | every pull request | An unsigned Release build for iOS devices with Xcode 26, to catch a broken build before merge |
| `deploy-ios-testflight.yml` | a PR merged with the `deploy-ios` label, or run by hand | Archives, signs and uploads to TestFlight |

How the deploy signs, where its secrets live and what each failure means is in CLAUDE.md, "TestFlight deploy pipeline".
