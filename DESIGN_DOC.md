# LittleChef - Design Document

## Table of Contents
- [1. Project Overview](#1-project-overview)
- [2. Technical Architecture](#2-technical-architecture)
- [3. Data Models](#3-data-models)
- [4. API Design](#4-api-design)
- [5. LangGraph Agent Architecture](#5-langgraph-agent-architecture)
- [6. iOS Application Design](#6-ios-application-design)
- [7. User Management & Cloud Storage](#7-user-management--cloud-storage)
- [8. Development Plan](#8-development-plan)
- [9. Future Features Roadmap](#9-future-features-roadmap)
- [10. Technical Specifications](#10-technical-specifications)

---

## 1. Project Overview

### 1.1 Vision Statement
LittleChef is a hands-free iOS cooking assistant that transforms any recipe into an interactive cooking companion using advanced LLM agents and voice interaction.

### 1.2 Core Value Proposition
- **Hands-Free Cooking**: Voice-driven interaction while your hands are busy cooking
- **Intelligent Recipe Assistant**: Context-aware help with ingredient substitutions, serving adjustments, and cooking questions
- **Recipe Intelligence**: Parse any recipe from URL, image, or text into a standardized format
- **Seamless Sync**: Access your recipes across all devices with cloud synchronization

### 1.3 Target Users
- Home cooks who want intelligent assistance while cooking
- People learning to cook who need guidance and substitution suggestions
- Experienced cooks who want hands-free access to recipe information
- Anyone who wants to modify recipes on the fly (servings, substitutions, etc.)

### 1.4 Key Features (MVP)
1. **Recipe Management**: Upload recipes via URL, image, or text
2. **Voice Assistant**: Hands-free Q&A about recipes while cooking
3. **Recipe Intelligence**: LLM-powered recipe parsing and modification
4. **Cloud Sync**: Store and sync recipes across devices
5. **Cooking Sessions**: Start a cooking session with any recipe as context

---

## 2. Technical Architecture

### 2.1 High-Level System Architecture

```mermaid
graph TB
    subgraph "iOS Frontend"
        A[SwiftUI App] --> B[Voice Service]
        A --> C[Recipe Manager]
        A --> D[Cooking Session Manager]
        A --> E[Core Data Storage]
    end
    
    subgraph "Backend Services"
        F[FastAPI Server] --> G[LangGraph Agent]
        F --> H[Recipe Parser]
        F --> I[PostgreSQL Database]
    end
    
    subgraph "External Services"
        J[OpenAI API]
        L[Speech Recognition]
        M[Text-to-Speech]
    end
    
    A <--> F
    G --> J
    B --> L
    B --> M
    
    style A fill:#e1f5fe
    style F fill:#f3e5f5
    style G fill:#fff3e0
```

### 2.2 Technology Stack

**iOS Frontend:**
- **UI Framework**: SwiftUI for modern, declarative UI
- **Data Persistence**: SwiftData/Core Data for local storage
- **Voice**: Speech Framework (recognition) + AVFoundation (synthesis)
- **Networking**: URLSession with async/await
- **Architecture**: MVVM with Combine/ObservableObject

**Backend:**
- **API Framework**: FastAPI (Python) for high-performance async API
- **Agent Framework**: LangGraph for complex agent workflows
- **Database**: PostgreSQL for reliable cloud storage
- **Authentication**: JWT tokens with refresh mechanism
- **LLM Integration**: OpenAI SDK

**Infrastructure:**
- **Development**: Local development environment
- **Production**: AWS (ECS for API, RDS for database)
- **Storage**: PostgreSQL for structured data, S3 for images (future)

### 2.3 Design Principles

1. **Offline Recipe Access**: View and browse locally stored recipes without internet
2. **Voice-Optimized**: All interactions designed for hands-free use
3. **Stateless Backend**: Each request contains full context for easy scaling
4. **Simple Data Models**: Flat structures optimized for LLM processing
5. **Real-time Responsiveness**: Fast voice recognition and synthesis

---

## 3. Data Models

### 3.1 Unified State Structure

The core innovation is using a unified `CookingSession` state that's shared between iOS and backend:

```python
class CookingSession:
    id: UUID
    recipe: Recipe
    modifications: RecipeModifications
    active_timers: List[Timer]
    conversation_history: List[Message]
    user_preferences: UserPreferences
    started_at: datetime

class Recipe:
    id: UUID
    title: str
    description: Optional[str]
    servings: int
    prep_time: Optional[int]  # minutes
    cook_time: Optional[int]  # minutes
    ingredients: List[str]    # Simple string list for LLM processing
    instructions: List[str]   # Simple string list for flexibility
    tags: List[str]
    source_url: Optional[str]
    cuisine_type: Optional[str]
    difficulty: Optional[str]

class RecipeModifications:
    serving_multiplier: float = 1.0           # 2.0 = double recipe
    ingredient_substitutions: Dict[str, str]  # "butter": "olive oil"
    notes: List[str]                          # User or agent added notes
    
class Timer:
    id: UUID
    label: str
    duration_seconds: int
    remaining_seconds: int
    is_active: bool
    created_at: datetime

class Message:
    id: UUID
    role: str        # "user" or "assistant"
    content: str
    timestamp: datetime

class UserPreferences:
    llm_model: Literal["gpt-5", "gpt-5-mini", "gpt-5-nano", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"]
    measurement_system: str                 # "metric" or "imperial"
    dietary_restrictions: List[str]
    voice_settings: VoiceSettings

class VoiceSettings:
    speech_rate: float = 0.5
    voice_identifier: str = "com.apple.ttsbundle.Samantha-compact"
    auto_speak_responses: bool = True
```

### 3.2 Database Schema

```sql
-- Users table
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    preferences JSONB DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Recipes table (stores full Recipe objects as JSONB)
CREATE TABLE recipes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipe_data JSONB NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Optional: Cooking sessions for analytics/resume functionality
CREATE TABLE cooking_sessions (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id),
    session_data JSONB NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX idx_recipes_user_id ON recipes(user_id);
CREATE INDEX idx_recipes_updated_at ON recipes(updated_at);
CREATE INDEX idx_recipes_title ON recipes USING gin((recipe_data->>'title') gin_trgm_ops);
```

### 3.3 iOS Core Data Models

```swift
@Model
class LocalRecipe {
    var id: UUID
    var cloudRecipeId: UUID?
    var recipeData: Data      // JSON-encoded Recipe
    var lastModified: Date
    var needsSync: Bool
    var isDeleted: Bool
    
    var recipe: Recipe {
        get { try! JSONDecoder().decode(Recipe.self, from: recipeData) }
        set { 
            recipeData = try! JSONEncoder().encode(newValue)
            lastModified = Date()
            needsSync = true
        }
    }
}

@Model
class LocalCookingSession {
    var id: UUID
    var sessionData: Data     // JSON-encoded CookingSession
    var isActive: Bool
    var lastUpdated: Date
    
    var cookingSession: CookingSession {
        get { try! JSONDecoder().decode(CookingSession.self, from: sessionData) }
        set { 
            sessionData = try! JSONEncoder().encode(newValue)
            lastUpdated = Date()
        }
    }
}
```

---

## 4. API Design

### 4.1 Authentication Endpoints

```python
POST /auth/register
{
    "email": "user@example.com",
    "password": "secure_password",
    "name": "John Doe"
}
Response: {
    "access_token": "jwt_token",
    "refresh_token": "refresh_token",
    "user": { "id": "uuid", "email": "...", "name": "..." },
    "expires_in": 3600
}

POST /auth/login
POST /auth/refresh
POST /auth/logout
```

### 4.2 Recipe Management Endpoints

```python
# Get all user recipes for sync
GET /recipes/
Response: [
    {
        "id": "uuid",
        "recipe_data": { /* Recipe object */ },
        "created_at": "2024-01-01T00:00:00Z",
        "updated_at": "2024-01-01T00:00:00Z"
    }
]

# Create/update recipe
POST /recipes/
PUT /recipes/{recipe_id}
{
    "recipe_data": {
        "title": "Chocolate Chip Cookies",
        "servings": 24,
        "ingredients": [
            "2 cups all-purpose flour",
            "1 cup butter, softened",
            "3/4 cup brown sugar"
        ],
        "instructions": [
            "Preheat oven to 375°F",
            "Mix dry ingredients in bowl",
            "Cream butter and sugar"
        ]
    }
}

# Delete recipe
DELETE /recipes/{recipe_id}

# Get specific recipe
GET /recipes/{recipe_id}
```

### 4.3 Recipe Parsing Endpoints

```python
POST /parse/url
{
    "url": "https://example.com/recipe"
}

POST /parse/text
{
    "text": "Recipe text content..."
}

POST /parse/image
{
    "image": "base64_encoded_image"
}

# All return:
{
    "recipe": {
        "title": "Parsed Recipe Title",
        "ingredients": [...],
        "instructions": [...],
        "servings": 4,
        "prep_time": 15,
        "cook_time": 30
    },
    "confidence": 0.95,
    "warnings": ["Could not parse prep time"]
}
```

### 4.4 LLM Agent Endpoint

```python
POST /agent/chat
{
    "cooking_session": {
        "id": "session_uuid",
        "recipe": { /* full recipe object */ },
        "modifications": {
            "serving_multiplier": 1.5,
            "ingredient_substitutions": {},
            "notes": []
        },
        "active_timers": [],
        "conversation_history": [
            {
                "role": "user",
                "content": "How long should I bake this?",
                "timestamp": "2024-01-01T00:00:00Z"
            }
        ],
        "user_preferences": {
            "llm_model": "gpt-5",
            "measurement_system": "imperial"
        }
    },
    "query": "Can I substitute almond flour for regular flour?"
}

Response:
{
    "response": "Yes, you can substitute almond flour, but use 3/4 the amount since it's denser...",
    "updated_session": {
        /* Updated CookingSession with new message in history */
        /* Potentially modified recipe or new timers */
    },
    "suggested_actions": [
        {
            "type": "recipe_modification",
            "description": "Updated flour amount for almond flour substitution"
        }
    ]
}
```

---

## 5. LangGraph Agent Architecture

### 5.1 Agent State Flow

```python
from langgraph import StateGraph
from typing import TypedDict, List

class AgentState(TypedDict):
    cooking_session: CookingSession
    current_query: str
    response: str
    tools_called: List[str]
    needs_recipe_update: bool
    suggested_timers: List[Timer]
    error: Optional[str]

def create_cooking_agent():
    workflow = StateGraph(AgentState)
    
    # Core agent nodes
    workflow.add_node("analyze_query", analyze_user_query)
    workflow.add_node("answer_question", answer_cooking_question)
    workflow.add_node("modify_recipe", modify_recipe_node)
    workflow.add_node("manage_timers", timer_management_node)
    workflow.add_node("synthesize_response", create_final_response)
    workflow.add_node("error_handler", handle_errors)
    
    # Define the flow
    workflow.set_entry_point("analyze_query")
    
    workflow.add_conditional_edges(
        "analyze_query",
        route_based_on_query_type,
        {
            "question": "answer_question",
            "recipe_modification": "modify_recipe", 
            "timer_request": "manage_timers",
            "error": "error_handler"
        }
    )
    
    workflow.add_edge("answer_question", "synthesize_response")
    workflow.add_edge("modify_recipe", "synthesize_response")
    workflow.add_edge("manage_timers", "synthesize_response")
    workflow.add_edge("error_handler", "synthesize_response")
    
    workflow.set_finish_point("synthesize_response")
    
    return workflow.compile()
```

### 5.2 Agent Tools

```python
class RecipeTools:
    def adjust_servings(self, recipe: Recipe, new_servings: int) -> Recipe:
        """Scale all ingredient amounts for new serving size"""
        multiplier = new_servings / recipe.servings
        
        # Use LLM to intelligently scale ingredients
        scaled_ingredients = []
        for ingredient in recipe.ingredients:
            scaled = self.llm.scale_ingredient(ingredient, multiplier)
            scaled_ingredients.append(scaled)
            
        return recipe.copy(update={
            "servings": new_servings,
            "ingredients": scaled_ingredients
        })
    
    def substitute_ingredient(self, recipe: Recipe, old_ingredient: str, 
                            new_ingredient: str, reason: str = "") -> Recipe:
        """Replace ingredient with substitution"""
        # Use LLM to determine proper substitution ratios
        substitution_info = self.llm.get_substitution_info(
            old_ingredient, new_ingredient, recipe.title
        )
        
        updated_ingredients = []
        for ingredient in recipe.ingredients:
            if old_ingredient.lower() in ingredient.lower():
                new_ingredient_text = self.llm.rewrite_ingredient_line(
                    ingredient, old_ingredient, new_ingredient, substitution_info
                )
                updated_ingredients.append(new_ingredient_text)
            else:
                updated_ingredients.append(ingredient)
                
        return recipe.copy(update={"ingredients": updated_ingredients})

class TimerTools:
    def set_timer(self, duration_minutes: int, label: str) -> Timer:
        """Create a new cooking timer"""
        return Timer(
            id=uuid4(),
            label=label,
            duration_seconds=duration_minutes * 60,
            remaining_seconds=duration_minutes * 60,
            is_active=True,
            created_at=datetime.now()
        )
    
    def check_active_timers(self, timers: List[Timer]) -> List[Timer]:
        """Update timer states and return active ones"""
        active_timers = []
        for timer in timers:
            if timer.is_active:
                # Calculate remaining time
                elapsed = (datetime.now() - timer.created_at).total_seconds()
                remaining = max(0, timer.duration_seconds - elapsed)
                
                if remaining > 0:
                    timer.remaining_seconds = int(remaining)
                    active_timers.append(timer)
                else:
                    timer.is_active = False
                    timer.remaining_seconds = 0
                    
        return active_timers

class KnowledgeTools:
    def get_cooking_knowledge(self, query: str, recipe_context: Recipe, model: str) -> str:
        """Get cooking knowledge relevant to the query and recipe"""
        # Use specialized cooking knowledge prompts
        context = f"Recipe: {recipe_context.title}\n"
        context += f"Ingredients: {', '.join(recipe_context.ingredients[:5])}\n"
        context += f"Cuisine: {recipe_context.cuisine_type or 'General'}"
        
        # Set reasoning_effort for GPT-5 models
        if model.startswith("gpt-5"):
            return self.llm.get_cooking_advice(query, context, reasoning_effort="minimal")
        else:
            return self.llm.get_cooking_advice(query, context)
```

### 5.3 Model Selection Strategy

```python
# LangGraph LLM Configuration for LittleChef
from langchain.chat_models import ChatOpenAI
from typing import Literal

LLMConfigType = Literal["tool", "response"]

def create_llm(model_name: str, llm_config: LLMConfigType = "tool") -> ChatOpenAI:
    """Create LLM with specified configuration for different use cases"""
    
    if llm_config == "tool":
        # Optimized for tool calling and complex reasoning
        base_config = {
            "model": model_name,
            "temperature": 0.2,  # Very low temp for precise tool calls
            "max_tokens": 3000,  # High limit for complex tool operations
            "request_timeout": 45,
            "max_retries": 3
        }
        
        # GPT-5 specific configuration for tool calling
        if model_name.startswith("gpt-5"):
            base_config.update({
                "reasoning_effort": "minimal",  # Still fast, but can handle complexity
            })
    
    elif llm_config == "response":
        # Optimized for final user responses
        base_config = {
            "model": model_name,
            "temperature": 0.4,  # Slightly higher for natural conversation
            "max_tokens": 400,   # Limited for concise voice responses
            "request_timeout": 20,  # Faster timeout for user-facing responses
            "max_retries": 3
        }
        
        # GPT-5 specific configuration for responses
        if model_name.startswith("gpt-5"):
            base_config.update({
                "reasoning_effort": "minimal",  # Fast responses
                "verbosity": "low"              # Concise answers for voice
            })
    
    return ChatOpenAI(**base_config)

# Example usage in LangGraph agent with config parameter
def create_cooking_agent(model_name: str):
    tool_llm = create_llm(model_name, llm_config="tool")         # For complex reasoning & tool calls
    response_llm = create_llm(model_name, llm_config="response") # For user-facing responses
    
    workflow = StateGraph(AgentState)
    
    # Add nodes with appropriate LLM configurations
    workflow.add_node("analyze_query", lambda state: analyze_query_node(state, tool_llm))
    workflow.add_node("recipe_modifier", lambda state: recipe_modifier_node(state, tool_llm))
    workflow.add_node("timer_manager", lambda state: timer_manager_node(state, tool_llm))
    workflow.add_node("response_synthesizer", lambda state: response_synthesizer_node(state, response_llm))
    
    # Tool nodes use "tool" config (3000 tokens, precise)
    # Response synthesis uses "response" config (400 tokens, conversational)
    
    return workflow.compile()

class ModelSelector:
    MODEL_CONFIGS = {
        "gpt-5": {"provider": "openai", "cost": "highest", "quality": "highest", "reasoning_effort": "minimal"},
        "gpt-5-mini": {"provider": "openai", "cost": "high", "quality": "high", "reasoning_effort": "minimal"},
        "gpt-5-nano": {"provider": "openai", "cost": "medium", "quality": "medium", "reasoning_effort": "minimal"},
        "gpt-4.1": {"provider": "openai", "cost": "high", "quality": "high"},
        "gpt-4.1-mini": {"provider": "openai", "cost": "medium", "quality": "medium"},
        "gpt-4.1-nano": {"provider": "openai", "cost": "low", "quality": "medium"}
    }
    
    def select_model(self, query_type: str, user_preferences: UserPreferences) -> str:
        """Select optimal model based on query type and user preferences"""
        
        # Respect user preference if specified
        if user_preferences.llm_model:
            return user_preferences.llm_model
            
        # Auto-select based on query complexity
        if query_type in ["recipe_modification", "complex_substitution"]:
            return "gpt-5"  # Use highest quality for complex tasks
        elif query_type in ["simple_question", "basic_cooking_advice"]:
            return "gpt-5-nano"  # Use efficient model for simple questions
        else:
            return "gpt-4.1"  # Default to balanced option
    
    def get_tool_model(self, base_model: str) -> str:
        """Get model optimized for tool calling (may be different from response model)"""
        # For complex tool operations, consider using higher-tier models
        if base_model == "gpt-5-nano":
            return "gpt-5-mini"  # Upgrade for tool precision
        return base_model  # Use same model for others
    
    def get_response_model(self, base_model: str) -> str:
        """Get model optimized for user responses (may be different from tool model)"""
        # Response model can be more cost-effective since it's simpler
        return base_model  # Keep same model for consistency
```

---

## 6. iOS Application Design

### 6.1 App Architecture

```swift
// Main App Structure
@main
struct LittleChefApp: App {
    @StateObject private var authManager = AuthManager()
    @StateObject private var recipeManager = RecipeManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authManager)
                .environmentObject(recipeManager)
                .onAppear {
                    authManager.initializeAuth()
                }
        }
    }
}

// Root Content View
struct ContentView: View {
    @EnvironmentObject var authManager: AuthManager
    
    var body: some View {
        Group {
            if authManager.isAuthenticated {
                MainTabView()
            } else {
                AuthenticationView()
            }
        }
    }
}
```

### 6.2 Core View Structure

```swift
struct MainTabView: View {
    var body: some View {
        TabView {
            RecipeListView()
                .tabItem {
                    Image(systemName: "book.fill")
                    Text("Recipes")
                }
            
            CookingSessionView()
                .tabItem {
                    Image(systemName: "flame.fill")
                    Text("Cook")
                }
            
            SettingsView()
                .tabItem {
                    Image(systemName: "gear.fill")
                    Text("Settings")
                }
        }
    }
}

struct RecipeListView: View {
    @EnvironmentObject var recipeManager: RecipeManager
    @State private var showingAddRecipe = false
    
    var body: some View {
        NavigationView {
            List(recipeManager.recipes) { recipe in
                RecipeRowView(recipe: recipe)
                    .onTapGesture {
                        // Navigate to recipe detail
                    }
            }
            .navigationTitle("My Recipes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        showingAddRecipe = true
                    }
                }
            }
            .sheet(isPresented: $showingAddRecipe) {
                AddRecipeView()
            }
        }
    }
}
```

### 6.3 Voice Integration

```swift
class VoiceAssistant: ObservableObject {
    @Published var isListening = false
    @Published var recognizedText = ""
    @Published var isSpeaking = false
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    
    func startListening() {
        guard let speechRecognizer = speechRecognizer,
              speechRecognizer.isAvailable else {
            return
        }
        
        isListening = true
        
        // Configure audio session for hands-free use
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        // Start speech recognition
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        
        speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result = result {
                DispatchQueue.main.async {
                    self?.recognizedText = result.bestTranscription.formattedString
                }
            }
        }
        
        // Start audio engine
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }
        
        audioEngine.prepare()
        try? audioEngine.start()
    }
    
    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isListening = false
    }
    
    func speak(_ text: String) {
        guard !isSpeaking else { return }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        
        isSpeaking = true
        synthesizer.speak(utterance)
        
        // Reset speaking state when done
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(text.count) * 0.05) {
            self.isSpeaking = false
        }
    }
}
```

### 6.4 Cooking Session Management

```swift
class CookingSessionManager: ObservableObject {
    @Published var currentSession: CookingSession?
    @Published var isLoading = false
    @Published var error: String?
    
    private let apiService = APIService()
    private let voiceAssistant = VoiceAssistant()
    
    func startCookingSession(with recipe: Recipe) {
        currentSession = CookingSession(
            id: UUID(),
            recipe: recipe,
            modifications: RecipeModifications(),
            activeTimers: [],
            conversationHistory: [],
            userPreferences: UserDefaults.shared.userPreferences,
            startedAt: Date()
        )
    }
    
    func sendVoiceQuery(_ query: String) async {
        guard var session = currentSession else { return }
        
        // Add user message
        let userMessage = Message(
            id: UUID(),
            role: "user", 
            content: query,
            timestamp: Date()
        )
        session.conversationHistory.append(userMessage)
        
        await MainActor.run {
            self.currentSession = session
            self.isLoading = true
        }
        
        do {
            // Send to agent
            let response = await apiService.sendAgentQuery(
                session: session,
                query: query
            )
            
            await MainActor.run {
                self.currentSession = response.updatedSession
                self.isLoading = false
                
                // Speak the response
                self.voiceAssistant.speak(response.response)
            }
            
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    
    func addTimer(duration: TimeInterval, label: String) {
        guard var session = currentSession else { return }
        
        let timer = Timer(
            id: UUID(),
            label: label,
            durationSeconds: Int(duration),
            remainingSeconds: Int(duration),
            isActive: true,
            createdAt: Date()
        )
        
        session.activeTimers.append(timer)
        currentSession = session
        
        // Set iOS timer for notification
        scheduleTimerNotification(timer: timer)
    }
    
    private func scheduleTimerNotification(timer: Timer) {
        let content = UNMutableNotificationContent()
        content.title = "LittleChef Timer"
        content.body = "\(timer.label) is ready!"
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(timer.durationSeconds),
            repeats: false
        )
        
        let request = UNNotificationRequest(
            identifier: timer.id.uuidString,
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request)
    }
}
```

---

## 7. User Management & Cloud Storage

### 7.1 Authentication Strategy

```swift
class AuthManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var isLoading = false
    
    private let keychain = KeychainWrapper()
    private let apiService = APIService()
    
    func register(email: String, password: String, name: String) async -> Result<User, AuthError> {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let response = try await apiService.register(
                email: email,
                password: password,
                name: name
            )
            
            // Store tokens securely
            keychain.set(response.accessToken, forKey: "access_token")
            keychain.set(response.refreshToken, forKey: "refresh_token")
            
            await MainActor.run {
                self.currentUser = response.user
                self.isAuthenticated = true
            }
            
            return .success(response.user)
            
        } catch {
            return .failure(AuthError.registrationFailed(error.localizedDescription))
        }
    }
    
    func login(email: String, password: String) async -> Result<User, AuthError> {
        // Similar implementation
    }
    
    func logout() {
        keychain.removeAllKeys()
        currentUser = nil
        isAuthenticated = false
    }
    
    func initializeAuth() {
        // Auto-login with stored tokens
        if let token = keychain.string(forKey: "access_token") {
            Task {
                await validateAndRefreshToken()
            }
        }
    }
}
```

### 7.2 Recipe Sync Strategy

```swift
class RecipeSyncManager: ObservableObject {
    @Published var recipes: [Recipe] = []
    @Published var syncStatus: SyncStatus = .idle
    
    private let coreDataStack = CoreDataStack()
    private let apiService = APIService()
    
    enum SyncStatus {
        case idle, syncing, error(String)
    }
    
    func performFullSync() async {
        syncStatus = .syncing
        
        do {
            // 1. Upload local changes
            let localRecipes = try coreDataStack.getRecipesNeedingSync()
            for localRecipe in localRecipes {
                if localRecipe.isDeleted {
                    try await apiService.deleteRecipe(id: localRecipe.cloudRecipeId!)
                    try coreDataStack.delete(localRecipe)
                } else if localRecipe.cloudRecipeId == nil {
                    // New recipe
                    let response = try await apiService.createRecipe(localRecipe.recipe)
                    localRecipe.cloudRecipeId = response.id
                    localRecipe.needsSync = false
                    try coreDataStack.save()
                } else {
                    // Updated recipe
                    try await apiService.updateRecipe(
                        id: localRecipe.cloudRecipeId!,
                        recipe: localRecipe.recipe
                    )
                    localRecipe.needsSync = false
                    try coreDataStack.save()
                }
            }
            
            // 2. Download cloud recipes
            let cloudRecipes = try await apiService.getUserRecipes()
            
            // 3. Merge with local storage
            for cloudRecipe in cloudRecipes {
                if let existingLocal = try coreDataStack.findRecipe(cloudId: cloudRecipe.id) {
                    // Update existing
                    if cloudRecipe.updatedAt > existingLocal.lastModified {
                        existingLocal.recipe = cloudRecipe.recipeData
                        existingLocal.needsSync = false
                    }
                } else {
                    // Create new local recipe
                    try coreDataStack.createLocalRecipe(
                        from: cloudRecipe.recipeData,
                        cloudId: cloudRecipe.id
                    )
                }
            }
            
            // 4. Update UI
            let allRecipes = try coreDataStack.fetchAllRecipes()
            await MainActor.run {
                self.recipes = allRecipes
                self.syncStatus = .idle
            }
            
        } catch {
            await MainActor.run {
                self.syncStatus = .error(error.localizedDescription)
            }
        }
    }
    
    func saveRecipe(_ recipe: Recipe) {
        // Save locally immediately
        do {
            try coreDataStack.saveRecipe(recipe, needsSync: true)
            recipes.append(recipe)
            
            // Background sync
            Task {
                await performFullSync()
            }
        } catch {
            print("Failed to save recipe locally: \(error)")
        }
    }
}
```

---

## 8. Development Plan

### 8.1 MVP Development Phases

#### Phase 1: Foundation (Weeks 1-3)
**Goal**: Basic app structure and authentication

**Backend Tasks:**
- [ ] Set up FastAPI project structure
- [ ] Implement user authentication (JWT)
- [ ] Set up PostgreSQL database with basic schema
- [ ] Create user registration/login endpoints
- [ ] Basic recipe CRUD endpoints

**iOS Tasks:**
- [ ] Create SwiftUI project structure
- [ ] Implement authentication UI and logic
- [ ] Set up Core Data stack for local storage
- [ ] Create basic recipe list and detail views
- [ ] Implement API service layer

**Deliverables:**
- Users can register/login
- Basic recipe storage (local and cloud)
- Simple recipe viewing interface

#### Phase 2: Recipe Intelligence (Weeks 4-6)
**Goal**: Recipe parsing and LLM integration

**Backend Tasks:**
- [ ] Integrate OpenAI SDK
- [ ] Implement recipe parsing from URL and text
- [ ] Create basic LangGraph agent structure
- [ ] Build recipe parsing endpoints
- [ ] Add basic cooking Q&A functionality

**iOS Tasks:**
- [ ] Create recipe upload flow (URL/text input)
- [ ] Implement recipe parsing UI
- [ ] Add recipe editing capabilities
- [ ] Create basic chat interface for testing agent

**Deliverables:**
- Users can upload recipes from URLs or text
- LLM parses recipes into standardized format
- Basic Q&A about recipes works

#### Phase 3: Voice Integration (Weeks 7-9)
**Goal**: Hands-free voice interaction

**Backend Tasks:**
- [ ] Enhance agent with cooking-specific tools
- [ ] Implement recipe modification capabilities
- [ ] Add timer management to agent responses
- [ ] Optimize agent response times

**iOS Tasks:**
- [ ] Implement Speech Framework integration
- [ ] Add text-to-speech for responses
- [ ] Create cooking session management
- [ ] Build hands-free cooking interface
- [ ] Implement timer notifications

**Deliverables:**
- Fully hands-free voice interaction
- Users can start cooking sessions with recipes
- Voice Q&A works reliably during cooking
- Timer management through voice

#### Phase 4: Polish & Testing (Weeks 10-12)
**Goal**: Production-ready MVP

**Backend Tasks:**
- [ ] Performance optimization
- [ ] Error handling and logging
- [ ] API rate limiting and security
- [ ] Prepare for AWS deployment

**iOS Tasks:**
- [ ] UI/UX polish and accessibility
- [ ] Offline recipe viewing testing
- [ ] App Store preparation
- [ ] Beta testing and bug fixes

**Deliverables:**
- Production-ready iOS app
- Stable backend service
- Comprehensive testing completed

### 8.2 Success Metrics for MVP

**Technical Metrics:**
- Voice recognition accuracy > 95%
- Agent response time < 3 seconds
- Recipe parsing accuracy > 90%
- App crash rate < 1%

**User Experience Metrics:**
- Successful recipe upload rate > 95%
- Voice interaction completion rate > 85%
- User retention after 1 week > 60%

### 8.3 Development Environment Setup

**Backend Setup:**
```bash
# Clone repository
git clone <repo-url>
cd little-chef/backend

# Create virtual environment
python -m venv venv
source venv/bin/activate  # or venv\Scripts\activate on Windows

# Install dependencies
pip install -r requirements.txt

# Set up environment variables
cp .env.example .env
# Edit .env with your API keys

# Set up database
docker-compose up -d postgres
python manage.py migrate

# Run development server
python manage.py runserver
```

**iOS Setup:**
```bash
# Open Xcode project
cd little-chef/ios
open little-chef.xcodeproj

# Install dependencies (if using SPM)
# Dependencies will be resolved automatically

# Set up development team and signing
# Configure API endpoints in Config.swift
```

---

## 9. Future Features Roadmap

### 9.1 Phase 5: Enhanced Intelligence (Months 4-6)

**Advanced Recipe Features:**
- [ ] **Recipe Scaling Intelligence**: Smart scaling that accounts for cooking physics (not just linear multiplication)
- [ ] **Ingredient Substitution Engine**: Comprehensive database of substitutions with ratios and cooking adjustments
- [ ] **Recipe Optimization**: AI suggestions for improving recipes based on cooking science
- [ ] **Multi-part Recipe Support**: Handle complex recipes with multiple components and timing coordination

**Enhanced Voice Capabilities:**
- [ ] **Custom Wake Word**: "Hey Chef" or similar for true hands-free activation
- [ ] **Contextual Understanding**: Remember previous questions in the conversation
- [ ] **Proactive Assistance**: Agent suggests next steps before being asked
- [ ] **Multiple Language Support**: Spanish, French, etc.

### 9.2 Phase 6: Social Features (Months 7-9)

**Recipe Sharing:**
- [ ] **Public Recipe Library**: Users can publish recipes for community access
- [ ] **Recipe Ratings & Reviews**: Community feedback on shared recipes
- [ ] **Recipe Collections**: Curated collections by cuisine, diet, difficulty
- [ ] **Social Following**: Follow favorite recipe creators

**Collaboration Features:**
- [ ] **Shared Recipe Lists**: Collaborate on meal planning with family/friends
- [ ] **Kitchen Sharing**: Multiple users cooking the same recipe simultaneously
- [ ] **Recipe Comments**: Leave notes and tips on shared recipes

### 9.3 Phase 7: Smart Kitchen Integration (Months 10-12)

**Kitchen Context:**
- [ ] **Kitchen Profiles**: Model different kitchens (home, friend's house, vacation rental)
- [ ] **Equipment Awareness**: Adjust recipes based on available equipment
- [ ] **Inventory Tracking**: Know what ingredients are available in each kitchen
- [ ] **Smart Appliance Integration**: Connect with IoT kitchen devices

**Meal Planning:**
- [ ] **Weekly Meal Planning**: AI-assisted meal planning with shopping lists
- [ ] **Dietary Goal Tracking**: Integration with health apps for nutrition goals
- [ ] **Leftover Management**: Suggest recipes to use up leftover ingredients
- [ ] **Seasonal Recommendations**: Suggest recipes based on seasonal ingredients

### 9.4 Phase 8: Advanced AI Features (Year 2)

**Computer Vision:**
- [ ] **Real-time Cooking Assessment**: Camera analysis of cooking progress
- [ ] **Ingredient Recognition**: Identify ingredients from photos for inventory
- [ ] **Technique Coaching**: Visual feedback on cooking techniques
- [ ] **Food Safety Monitoring**: Alert for potential food safety issues

**Personalization:**
- [ ] **Taste Profile Learning**: Learn user preferences and suggest modifications
- [ ] **Skill Level Adaptation**: Adjust instructions based on cooking experience
- [ ] **Health Integration**: Suggest recipe modifications for dietary restrictions
- [ ] **Cooking History Analytics**: Insights into cooking patterns and improvements

### 9.5 Platform Expansion

**Additional Platforms:**
- [ ] **iPad App**: Optimized for larger screen use in kitchen
- [ ] **Apple Watch**: Quick timer and notification access
- [ ] **Android Version**: Expand to Android ecosystem
- [ ] **Web App**: Browser-based access for recipe management

**Integration Opportunities:**
- [ ] **Apple HomeKit**: Smart home integration for kitchen automation
- [ ] **Apple Health**: Nutrition tracking and health goals
- [ ] **Siri Shortcuts**: Custom voice commands for common actions
- [ ] **Apple CarPlay**: Access recipes while grocery shopping

### 9.6 Business Model Evolution

**Monetization Strategy:**
- [ ] **Freemium Model**: Basic features free, advanced AI features premium
- [ ] **Subscription Tiers**: Different LLM access levels and features
- [ ] **Marketplace**: Premium recipe collections from professional chefs
- [ ] **Kitchen Partnerships**: Integration deals with appliance manufacturers

---

## 10. Technical Specifications

### 10.1 Performance Requirements

**iOS App Performance:**
- App launch time: < 2 seconds cold start
- Voice recognition latency: < 500ms
- Agent response time: < 3 seconds
- Offline recipe access: 100% of saved recipes
- Memory usage: < 150MB average

**Backend Performance:**
- API response time: < 1 second for simple queries
- Agent processing: < 3 seconds for complex queries
- Database query time: < 100ms average
- Concurrent users: Support 1000+ simultaneous sessions
- Uptime requirement: 99.9%

### 10.2 Security & Privacy

**Data Protection:**
- All recipes encrypted at rest and in transit
- User data never shared with third parties
- GDPR compliance for European users
- Local data deletion on user request
- Secure token-based authentication

**API Security:**
- Rate limiting: 100 requests/minute per user
- HTTPS enforcement for all endpoints
- Input validation and sanitization
- SQL injection protection
- API key rotation support

### 10.3 Scalability Considerations

**Backend Scaling:**
- Horizontally scalable FastAPI services
- Database connection pooling
- Redis caching for frequently accessed data
- CDN for recipe images (future)
- Auto-scaling based on load

**iOS Optimization:**
- Efficient Core Data usage with batch operations
- Background sync to minimize UI blocking
- Image caching and compression
- Memory management for large recipe collections

### 10.4 Development Dependencies

**Backend Dependencies:**
```python
# requirements.txt
fastapi==0.104.1
uvicorn==0.24.0
sqlalchemy==2.0.23
alembic==1.12.1
psycopg2-binary==2.9.9
pydantic==2.5.0
python-jose[cryptography]==3.3.0
passlib[bcrypt]==1.7.4
langchain==0.1.0
langgraph==0.1.0
langchain-openai==0.1.0
openai==1.12.0
python-multipart==0.0.6
pytest==7.4.3
pytest-asyncio==0.21.1
```

**iOS Dependencies:**
- iOS 17.0+ (SwiftUI, SwiftData)
- Speech Framework
- AVFoundation
- Network Framework
- CryptoKit for security

### 10.5 Deployment Architecture

**Local Development:**
```yaml
# docker-compose.yml
version: '3.8'
services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_DB: littlechef
      POSTGRES_USER: dev
      POSTGRES_PASSWORD: devpass
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:7
    ports:
      - "6379:6379"

  api:
    build: ./backend
    ports:
      - "8000:8000"
    depends_on:
      - postgres
      - redis
    environment:
      DATABASE_URL: postgresql://dev:devpass@postgres:5432/littlechef
      REDIS_URL: redis://redis:6379
```

**AWS Production Deployment:**
- **ECS Fargate**: Containerized FastAPI backend
- **RDS PostgreSQL**: Managed database service
- **ElastiCache Redis**: Caching layer
- **Application Load Balancer**: Traffic distribution
- **CloudFront CDN**: Asset delivery (future)
- **S3**: File storage for images (future)

---

## Conclusion

LittleChef represents a new paradigm in cooking assistance, combining the power of modern LLMs with intuitive voice interaction to create a truly hands-free cooking experience. The architecture is designed to be:

- **Scalable**: From MVP to millions of users
- **Extensible**: Easy to add new features and capabilities
- **Reliable**: Local recipe storage ensures viewing works without internet
- **Intelligent**: Advanced AI that understands cooking context and provides meaningful assistance

The development plan provides a clear path from MVP to a comprehensive cooking platform, with each phase building on the previous to create increasingly sophisticated functionality.

The future roadmap shows how LittleChef can evolve into a complete cooking ecosystem, potentially revolutionizing how people approach cooking at home.
