# 🍳 LittleChef

A hands-free iOS cooking assistant powered by advanced LLM agents and voice interaction. Transform any recipe into an interactive cooking companion that provides intelligent assistance while your hands are busy cooking.

## 🌟 Core Features

### 🎤 Voice-First Cooking Experience
- **Hands-Free Interaction**: Complete voice control while cooking - no need to touch your device with messy hands
- **Natural Language Q&A**: Ask questions like "How long do I cook this?" or "Can I substitute butter with oil?"
- **Smart Voice Recognition**: iOS native speech recognition optimized for kitchen environments
- **Flexible Text-to-Speech**: Choose between native iOS TTS or premium ElevenLabs voice synthesis

### 🤖 AI-Powered Cooking Assistant
- **LangGraph Agent Framework**: Advanced agent workflows that understand cooking context
- **Contextual Understanding**: Remembers your recipe, current step, and cooking session state
- **Intelligent Suggestions**: Proactive tips and recommendations based on your cooking progress
- **Multi-Model Support**: Supports GPT-4, GPT-5, and various OpenAI model tiers

### 📝 Smart Recipe Intelligence
- **Universal Recipe Parsing**: Extract structured recipes from any source:
  - 🌐 **URLs**: Parse recipes from any cooking website
  - 📸 **Images**: Extract recipes from photos of cookbooks or handwritten cards
  - 📄 **Text**: Convert plain text recipes into structured format
- **Automatic Standardization**: Converts all recipes into a consistent, structured format
- **Quality Validation**: Ensures parsed recipes are complete and accurate

### ⚖️ Dynamic Recipe Modification
- **Smart Scaling**: Intelligently adjust serving sizes with proper ingredient calculations
- **Ingredient Substitutions**: Real-time suggestions for ingredient replacements with proper ratios
- **Dietary Adaptations**: Modify recipes for dietary restrictions and preferences
- **Cooking Adjustments**: Adapt cooking times and temperatures based on modifications

### ⏱️ Intelligent Timer Management
- **Voice-Controlled Timers**: Set multiple timers using natural language
- **Smart Timer Suggestions**: Agent automatically suggests timers based on recipe steps
- **iOS Integration**: Native notifications and timer management
- **Context-Aware Timing**: Understands which step each timer relates to

### 📱 Local-First iOS Experience
- **SwiftUI Interface**: Modern, responsive design optimized for iOS
- **Core Data Storage**: All recipes and preferences stored locally on your device
- **CloudKit Sync**: Seamlessly sync your data across all your Apple devices
- **Privacy-Focused**: No backend storage - your data stays on your devices
- **Offline Access**: Full functionality without internet (except AI queries)

## 🏗️ Technical Architecture

### System Overview
```
┌─────────────────────────────────────────────────────────────┐
│                        iOS App (Local-First)                │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │   SwiftUI    │  │  Core Data   │  │   CloudKit   │     │
│  │   Interface  │  │  + Recipes   │  │     Sync     │     │
│  │              │  │  + Prefs     │  │              │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Voice Assistant (Speech + TTS + Audio Playback)    │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                           │ HTTPS
                           ▼
┌─────────────────────────────────────────────────────────────┐
│              AWS Serverless Backend (Stateless)             │
│                                                             │
│  ┌─────────────────────┐        ┌─────────────────────┐   │
│  │  Cooking Assistant  │        │   Recipe Parser     │   │
│  │      Lambda         │        │      Lambda         │   │
│  │                     │        │                     │   │
│  │  • LangGraph Agent  │        │  • URL Scraping     │   │
│  │  • Timer Commands   │        │  • Image OCR        │   │
│  │  • ElevenLabs TTS   │        │  • Text Parsing     │   │
│  └─────────────────────┘        └─────────────────────┘   │
│            │                              │                │
│            └──────────────┬───────────────┘                │
│                           │                                │
│                    API Gateway (HTTPS)                     │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │    External APIs       │
              │  • OpenAI (GPT-4/5)    │
              │  • ElevenLabs          │
              │  • Firecrawl           │
              └────────────────────────┘
```

### Core Technologies

**iOS Frontend:**
- SwiftUI for modern, declarative UI
- Core Data for local persistence
- CloudKit for cross-device sync
- Speech Framework for voice recognition
- AVFoundation for audio playback
- No authentication - completely local-first

**Serverless Backend:**
- AWS Lambda (Python 3.12) for stateless compute
- AWS API Gateway for HTTPS endpoints
- LangGraph for AI agent workflows
- LangChain for LLM orchestration
- AWS SAM for infrastructure-as-code

**AI/ML Services:**
- OpenAI GPT models (GPT-4, GPT-5-mini)
- LangChain + LangGraph agent framework
- Firecrawl for web scraping
- ElevenLabs for premium TTS (optional)

**Infrastructure:**
- AWS Lambda (serverless, pay-per-use)
- API Gateway (HTTPS endpoints)
- GitHub Actions (CI/CD)
- No database - fully stateless backend

## 📂 Project Structure

```
little-chef/
├── lambda/                          # Serverless backend
│   ├── cooking_assistant/           # AI cooking agent Lambda
│   │   ├── handler.py              # Lambda entry point
│   │   ├── cooking_agent.py        # LangGraph workflow
│   │   ├── agent_tools.py          # Timer tools
│   │   ├── prompts.py              # System prompts
│   │   ├── elevenlabs_service.py   # TTS integration
│   │   └── requirements.txt        # Python dependencies
│   ├── recipe_parser/               # Recipe parsing Lambda
│   │   ├── handler.py              # Lambda entry point
│   │   ├── recipe_parser.py        # Parsing logic
│   │   └── requirements.txt        # Python dependencies
│   ├── shared/                      # Shared code
│   │   └── schemas.py              # Pydantic models
│   └── template.yaml               # AWS SAM template
├── ios/little-chef/                 # iOS application
│   ├── Views/                       # SwiftUI views
│   │   ├── MainView.swift
│   │   ├── RecipeListView.swift
│   │   ├── CookingView.swift
│   │   └── SettingsView.swift
│   ├── Managers/                    # Business logic
│   │   ├── RecipeManager.swift     # Recipe CRUD (Core Data)
│   │   ├── CookingSessionManager.swift
│   │   ├── VoiceAssistant.swift
│   │   └── PreferencesManager.swift
│   ├── Services/                    # External services
│   │   └── APIService.swift        # Lambda API client
│   ├── Models/                      # Data models
│   │   ├── Recipe.swift
│   │   ├── CookingSession.swift
│   │   └── CoreData/               # Core Data entities
│   │       ├── RecipeEntity.swift
│   │       ├── UserPreferencesEntity.swift
│   │       └── PersistenceController.swift
│   └── Config.plist                # API configuration
└── .github/workflows/
    └── deploy-lambda.yml           # CI/CD pipeline
```

## 🚀 Quick Start

### Prerequisites

**For iOS Development:**
- macOS with Xcode 15+
- iOS 17+ device or simulator
- Apple Developer account (for CloudKit)

**For Lambda Deployment:**
- AWS account with CLI configured
- AWS SAM CLI installed
- Python 3.12+
- API keys: OpenAI, ElevenLabs (optional), Firecrawl

### Lambda Backend Setup

1. **Install AWS SAM CLI**
   ```bash
   brew install aws-sam-cli
   ```

2. **Configure AWS credentials**
   ```bash
   aws configure
   ```

3. **Deploy Lambda functions**
   ```bash
   cd lambda
   sam build
   sam deploy --guided
   ```

   During guided deployment:
   - Stack name: `littlechef-backend`
   - AWS Region: Your preferred region (e.g., `us-east-1`)
   - Confirm changes: Yes
   - Allow SAM CLI IAM role creation: Yes
   - Save arguments to configuration: Yes

4. **Update environment variables**

   After deployment, update Lambda environment variables with your API keys:

   ```bash
   # Update cooking assistant Lambda
   aws lambda update-function-configuration \
     --function-name littlechef-CookingAssistantFunction \
     --environment Variables="{
       OPENAI_API_KEY=your-openai-key,
       ELEVENLABS_API_KEY=your-elevenlabs-key
     }"

   # Update recipe parser Lambda
   aws lambda update-function-configuration \
     --function-name littlechef-RecipeParserFunction \
     --environment Variables="{
       OPENAI_API_KEY=your-openai-key,
       FIRECRAWL_API_KEY=your-firecrawl-key
     }"
   ```

5. **Note your API Gateway URL**

   The deployment outputs will include your API Gateway URL:
   ```
   Outputs:
     ApiGatewayUrl: https://xxxxxxxxxx.execute-api.us-east-1.amazonaws.com/Prod/
   ```

### iOS App Setup

1. **Clone and open in Xcode**
   ```bash
   git clone <repository-url>
   cd little-chef/ios
   open little-chef.xcodeproj
   ```

2. **Create Core Data model**

   The app uses Core Data for local storage. You need to create the data model file:

   - File → New → File → Data Model
   - Name it `LittleChef` (matches PersistenceController.swift)
   - Add two entities:

   **RecipeEntity:**
   - `id`: UUID
   - `title`: String
   - `recipeDataJSON`: String
   - `createdAt`: Date
   - `updatedAt`: Date

   **UserPreferencesEntity:**
   - `id`: UUID
   - `preferencesJSON`: String
   - `lastModified`: Date

3. **Configure API endpoint**

   Create `ios/little-chef/Config.plist`:
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>baseURL</key>
       <string>https://your-api-gateway-url.execute-api.us-east-1.amazonaws.com/Prod</string>
   </dict>
   </plist>
   ```

4. **Enable CloudKit**

   - Select your project in Xcode
   - Select your target → Signing & Capabilities
   - Click "+ Capability" → Add "iCloud"
   - Enable "CloudKit"
   - Update the CloudKit Container ID in [PersistenceController.swift:21](ios/little-chef/Models/CoreData/PersistenceController.swift#L21) to match your bundle ID

5. **Build and run**
   - Select your target device/simulator
   - Press ⌘R to build and run

## 📋 API Endpoints

### POST /v1/assistant
Interact with the cooking AI assistant.

**Request:**
```json
{
  "cooking_session": {
    "recipe": { /* RecipeBase */ },
    "commands": [ /* Command[] */ ],
    "timer_status": [ /* TimerStatus[] */ ],
    "conversation_history": [ /* Message[] */ ],
    "user_preferences": { /* UserPreferences */ },
    "started_at": "2024-01-01T12:00:00Z"
  },
  "query": "How long should I cook the chicken?"
}
```

**Response:**
```json
{
  "response": "Cook the chicken for 25-30 minutes...",
  "updated_session": { /* Updated CookingSession */ },
  "audio": "base64-encoded-audio-data" // Optional, if ElevenLabs enabled
}
```

### POST /v1/parse
Parse a recipe from URL, text, or images.

**Request (URL):**
```json
{
  "type": "url",
  "url": "https://example.com/recipe"
}
```

**Request (Text):**
```json
{
  "type": "text",
  "text": "Ingredients: 2 cups flour..."
}
```

**Request (Images):**
```json
{
  "type": "image",
  "images": ["base64-image-1", "base64-image-2"]
}
```

**Response:**
```json
{
  "recipe": {
    "title": "Chocolate Chip Cookies",
    "description": "Classic homemade cookies",
    "servings": 24,
    "prep_time": 15,
    "cook_time": 12,
    "ingredients": ["2 cups flour", "1 cup sugar", ...],
    "instructions": ["Preheat oven...", "Mix dry ingredients...", ...],
    "tags": ["dessert", "baking"],
    "cuisine_type": "American",
    "difficulty": "easy"
  },
  "metadata": {
    "source": "url",
    "confidence": 0.95
  }
}
```

## 💰 Cost Estimates

### AWS Lambda Costs (Monthly)
**Assumptions:**
- 100 cooking sessions/month
- Average 20 queries per session
- 10 recipe parses/month

**Lambda Compute:**
- Cooking assistant: 2,000 invocations × 2s × 512MB = $0.17
- Recipe parser: 10 invocations × 5s × 1024MB = $0.01
- **Total: ~$0.20/month**

**API Gateway:**
- 2,010 requests × $0.0000035 = $0.01/month

**Total AWS Infrastructure: ~$0.20-0.25/month**

### External API Costs
**OpenAI:**
- GPT-4: ~$0.03/query → $60/month (2,000 queries)
- GPT-5-mini: ~$0.001/query → $2/month (2,000 queries)

**ElevenLabs (Optional):**
- ~$0.30/1000 characters
- Average 200 chars/response → $120/month (2,000 responses)
- Alternative: Free iOS native TTS

**Firecrawl:**
- 500 free scrapes/month
- Additional: $0.003/scrape → $0.03/month (10 extra)

**Typical Monthly Cost:**
- Budget mode (GPT-5-mini + native TTS): **~$2.25**
- Premium mode (GPT-4 + ElevenLabs): **~$180**

## 🔒 Security & Privacy

### Local-First Privacy
- **No user accounts**: No authentication, no user data collection
- **Local storage**: All recipes and preferences stored on device
- **CloudKit sync**: Data syncs between your devices via Apple's secure infrastructure
- **No backend storage**: Lambda functions are stateless, data discarded after response

### API Security
- **HTTPS only**: All API communication encrypted via TLS
- **No PII**: Backend never receives or stores personal information
- **API keys in environment**: Secrets managed via AWS Secrets Manager (recommended)
- **Rate limiting**: Consider adding API Gateway rate limits for production

### Recommended Security Enhancements
1. **API Gateway API Keys**: Add API key requirement to prevent unauthorized access
2. **AWS WAF**: Add web application firewall for DDoS protection
3. **Secrets Manager**: Store API keys in AWS Secrets Manager instead of environment variables
4. **CloudWatch Monitoring**: Enable logging and alerting for suspicious activity

## 🔧 Development

### Local Lambda Testing

Test Lambda functions locally using SAM:

```bash
# Test cooking assistant
sam local invoke CookingAssistantFunction -e events/cooking_query.json

# Test recipe parser
sam local invoke RecipeParserFunction -e events/recipe_parse.json

# Start local API Gateway
sam local start-api
```

### iOS Development

**Running tests:**
```bash
xcodebuild test -scheme little-chef -destination 'platform=iOS Simulator,name=iPhone 15'
```

**View Core Data:**
- Use Xcode's Core Data debugger
- Launch app → Editor → Debug → Core Data

**CloudKit Dashboard:**
- [https://icloud.developer.apple.com/dashboard](https://icloud.developer.apple.com/dashboard)
- View sync status, records, and schema

### CI/CD Pipeline

The project includes GitHub Actions workflow for automated Lambda deployment:

**Trigger:** Push to `main` or `serverless-refactor` branch

**Steps:**
1. Checkout code
2. Configure AWS credentials
3. Install SAM CLI
4. Build Lambda functions
5. Deploy to AWS
6. Output API Gateway URL

**Setup:**
Add GitHub repository secrets:
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

## 🎯 Example Usage

### Typical Cooking Session Flow

1. **Import Recipe**
   - Open app → Add Recipe → Enter URL
   - App sends URL to `/v1/parse` Lambda
   - Recipe parsed and saved to Core Data

2. **Start Cooking Session**
   - Select recipe → Tap "Start Cooking"
   - Voice assistant activates
   - Session state stored locally

3. **Hands-Free Interaction**
   ```
   User: "How much flour do I need?"
   → Speech recognized via iOS Speech Framework
   → Sent to /v1/assistant Lambda with session context
   → AI responds: "You need 2 cups of all-purpose flour"
   → Response played via TTS (native or ElevenLabs)

   User: "Set a timer for 12 minutes"
   → Lambda returns timer command
   → iOS creates local timer
   → Notification when complete

   User: "Can I use honey instead of sugar?"
   → AI analyzes substitution
   → Updates recipe with new ingredient
   → Saved to Core Data
   ```

4. **Cross-Device Sync**
   - Recipe modifications sync via CloudKit
   - Access from iPhone, iPad, or Mac
   - Automatic conflict resolution

## 🤝 Contributing

This is a personal project, but suggestions and improvements are welcome!

## 📄 License

MIT License - feel free to use this project as a starting point for your own cooking assistant.

## 🙏 Acknowledgments

- **LangChain/LangGraph**: Agent framework
- **OpenAI**: GPT models
- **ElevenLabs**: Premium text-to-speech
- **Firecrawl**: Web scraping service
- **Apple**: SwiftUI, Core Data, CloudKit, Speech Framework

---

**Built with ❤️ for hands-free cooking**
