# 🍳 LittleChef

A hands-free iOS cooking assistant powered by advanced LLM agents and voice interaction. Transform any recipe into an interactive cooking companion that provides intelligent assistance while your hands are busy cooking.

## 🌟 Core Features

### 🎤 Voice-First Cooking Experience
- **Hands-Free Interaction**: Complete voice control while cooking - no need to touch your device with messy hands
- **Natural Language Q&A**: Ask questions like "How long do I cook this?" or "Can I substitute butter with oil?"
- **Smart Voice Recognition**: Optimized for kitchen environments with background noise
- **Text-to-Speech Responses**: Clear, natural-sounding answers using ElevenLabs voice synthesis

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
- **Smart Scaling**: Intelligently adjust serving sizes (not just linear multiplication)
- **Ingredient Substitutions**: Real-time suggestions for ingredient replacements with proper ratios
- **Dietary Adaptations**: Modify recipes for dietary restrictions and preferences
- **Cooking Adjustments**: Adapt cooking times and temperatures based on modifications

### ⏱️ Intelligent Timer Management
- **Voice-Controlled Timers**: Set multiple timers using natural language
- **Smart Timer Suggestions**: Agent automatically suggests timers based on recipe steps
- **iOS Integration**: Native notifications and timer management
- **Context-Aware Timing**: Understands which step each timer relates to

### 📱 Native iOS Experience
- **SwiftUI Interface**: Modern, responsive design optimized for iOS
- **Offline Recipe Access**: View and browse saved recipes without internet
- **Core Data Storage**: Efficient local storage with cloud synchronization
- **Background Processing**: Continue timers and sessions when app is backgrounded

### ☁️ Cloud Synchronization
- **Cross-Device Access**: Seamlessly sync recipes across all your devices
- **Secure Authentication**: JWT-based auth with secure keychain storage
- **Conflict Resolution**: Smart merging of changes made on different devices
- **Backup & Restore**: Never lose your recipe collection

## 🏗️ Technical Architecture

### System Overview
```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   iOS Frontend  │    │  FastAPI Backend │    │  External APIs  │
│                 │    │                 │    │                 │
│ • SwiftUI       │◄──►│ • LangGraph     │◄──►│ • OpenAI        │
│ • Voice I/O     │    │ • PostgreSQL    │    │ • ElevenLabs    │
│ • Core Data     │    │ • JWT Auth      │    │ • Firecrawl     │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

### Core Technologies
- **Frontend**: SwiftUI, Speech Framework, AVFoundation, Core Data
- **Backend**: FastAPI, LangGraph, SQLAlchemy, PostgreSQL
- **AI/ML**: OpenAI GPT models, LangChain, custom cooking agents
- **Voice**: iOS Speech Recognition, ElevenLabs TTS synthesis
- **Infrastructure**: AWS ECS/EC2, RDS, Docker containerization

## 🎯 User Experience

### Typical Cooking Session Flow

1. **Recipe Import**: "Hey, I found this great pasta recipe online" → Import via URL
2. **Session Start**: Select recipe → Start cooking session with voice assistant activated
3. **Hands-Free Cooking**: 
   - "How much salt do I need?" → Agent responds with exact measurement
   - "Set a timer for 8 minutes" → Timer automatically created and started
   - "Can I use olive oil instead of butter?" → Smart substitution with ratio adjustment
4. **Dynamic Adaptation**: Recipe automatically updates with your modifications
5. **Step Guidance**: "What's next?" → Agent guides you through the next cooking step
6. **Timer Management**: Automatic alerts when timers complete, multiple timers supported

### Example Voice Interactions

**Recipe Questions:**
- "How long do I cook the chicken?"
- "What temperature should the oven be?"
- "Can I substitute Greek yogurt for sour cream?"
- "How do I know when the onions are caramelized?"

**Cooking Assistance:**
- "Set a 15-minute timer for the rice"
- "Double this recipe for 8 people"
- "I don't have paprika, what can I use instead?"
- "How do I fix oversalted soup?"

**Session Management:**
- "Start cooking the lasagna recipe"
- "What step am I on?"
- "Save this modification to the recipe"
- "How much time is left on my timers?"

## 🧠 AI Agent Architecture

### LangGraph Workflow
The cooking assistant uses a sophisticated multi-node agent workflow:

```
User Query → Query Analysis → Context Understanding
     ↓
Recipe Knowledge → Cooking Tools → Response Generation
     ↓
Timer Management → Voice Synthesis → User Response
```

### Agent Capabilities

**Recipe Intelligence:**
- Parse and understand recipe structures
- Calculate ingredient scaling with cooking physics awareness
- Suggest substitutions based on dietary restrictions and availability
- Optimize cooking procedures for efficiency

**Cooking Knowledge:**
- Extensive database of cooking techniques and food science
- Temperature and timing recommendations
- Troubleshooting common cooking issues
- Dietary adaptation strategies

**Context Awareness:**
- Maintains session state throughout cooking
- Remembers previous questions and modifications
- Tracks active timers and cooking progress
- Personalizes responses based on user preferences

