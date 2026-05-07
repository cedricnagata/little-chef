# LittleChef

A hands-free iOS cooking assistant powered by on-device LLM inference and voice interaction. Transform any recipe into an interactive cooking companion that provides intelligent assistance while your hands are busy.

Available on TestFlight: https://testflight.apple.com/join/PFrfk3WY

## Features

### Voice-First Cooking
- Hands-free interaction — no need to touch the device while cooking
- Ask natural language questions: "How long do I cook this?" or "Can I substitute butter with oil?"
- Auto-speak responses via iOS text-to-speech

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

LittleChef supports two inference backends, selectable in Settings:

### On-Device (Local)
Runs [PrismML Bonsai 8B (1-bit)](https://huggingface.co/prism-ml/Bonsai-8B-mlx-1bit) directly on iPhone using [MLX](https://github.com/ml-explore/mlx-swift). The model handles both recipe parsing and cooking assistance. Requires a device with 6 GB of RAM (iPhone 16 Pro or later).

- No internet required after initial model download
- Full privacy — all inference runs on-device
- ~44 tok/s generation on iPhone 16 Pro Max

### BigBro (Mac Companion)
Pairs with a Mac running the BigBro companion app over local network. The Mac runs `gpt-oss:20b` and handles all inference, with tool use fully supported. Suitable for older devices that don't meet the RAM requirement.

- No model download on iPhone
- Full tool support (timers, recipe modifications)
- Requires a paired Mac on the same network

## Architecture

```
┌─────────────────────────────────────────┐
│              iOS App (SwiftUI)           │
│                                         │
│  RecipeListView → RecipeDetailView      │
│         ↓                               │
│  CookingSessionView + VoiceAssistant    │
│         ↓                               │
│     LocalCookingAgent                   │
│         ↓                               │
│  LLMService                             │
│  ├── Local: Bonsai 8B via MLX           │
│  └── BigBro: Mac companion via network  │
└─────────────────────────────────────────┘
```

**Key components:**
- `LLMService` — manages inference backend selection, model download/loading, and chat completions
- `LocalCookingAgent` — maintains conversation history and builds prompts for the cooking session
- `LocalRecipeParser` — parses recipes from URLs (schema.org + LLM cleanup), images (OCR), and text
- `BigBroClient` (BigBroKit) — handles pairing, connection, and streaming chat with the Mac companion
- `TimerManager` — manages multiple concurrent cooking timers with iOS notifications
- `LocalDataManager` — Core Data persistence for recipes and user preferences

## Tech Stack

- **UI**: SwiftUI, AVFoundation (TTS), Speech Framework (STT)
- **On-device inference**: MLX Swift, PrismML Bonsai 8B 1-bit
- **Mac inference**: BigBroKit (local network pairing)
- **Recipe parsing**: WebScraperService, OCRService, schema.org extraction
- **Storage**: Core Data
