"""
Pydantic schemas for Lambda functions
Contains only schemas needed for recipe parsing and cooking assistant
"""

from pydantic import BaseModel, Field, validator, field_serializer
from typing import Optional, Dict, Any, List, Literal
from datetime import datetime, timezone
import uuid


# ===== Voice Settings Schemas =====

class ElevenLabsSettings(BaseModel):
    """Schema for ElevenLabs voice synthesis settings"""
    enabled: bool = Field(default=False, description="Whether to use ElevenLabs for TTS")
    voice_name: str = Field(default="Rachel - calm", description="ElevenLabs voice name (e.g., 'Rachel - calm', 'Josh - intelligent')")


class VoiceSettings(BaseModel):
    """Schema for voice settings"""
    # Native iOS/System TTS settings
    speech_rate: float = Field(default=0.5, ge=0.1, le=2.0)
    voice_identifier: str = Field(default="com.apple.ttsbundle.Samantha-compact")
    auto_speak_responses: bool = True

    # ElevenLabs settings
    elevenlabs: ElevenLabsSettings = Field(default_factory=ElevenLabsSettings)


class UserPreferences(BaseModel):
    """Schema for user preferences"""
    llm_model: str = Field("gpt-4.1", pattern="^(gpt-4.1|gpt-4.1-mini)$")
    measurement_system: str = Field("imperial", pattern="^(metric|imperial)$")
    dietary_restrictions: list[str] = Field(default_factory=list)
    voice_settings: VoiceSettings = Field(default_factory=VoiceSettings)


class UserPreferencesDetailed(UserPreferences):
    """Extended user preferences with voice settings"""
    voice_settings: VoiceSettings = Field(default_factory=VoiceSettings)


# ===== Recipe Schemas =====

class RecipeBase(BaseModel):
    """Base recipe schema matching design document"""
    title: str = Field(..., min_length=1, max_length=255)
    description: Optional[str] = None
    servings: int = Field(default=4, ge=1, le=100)
    prep_time: Optional[int] = Field(None, ge=0, le=1440)  # max 24 hours in minutes
    cook_time: Optional[int] = Field(None, ge=0, le=1440)  # max 24 hours in minutes
    ingredients: List[str] = Field(..., min_items=1)
    instructions: List[str] = Field(..., min_items=1)
    tags: List[str] = Field(default_factory=list)
    source_url: Optional[str] = None
    cuisine_type: Optional[str] = None
    difficulty: Optional[str] = Field(None, pattern="^(easy|medium|hard)$")


# ===== Recipe Parsing Schemas =====

class RecipeParseUrlRequest(BaseModel):
    """Schema for URL parsing request"""
    type: Literal["url"] = "url"
    url: str = Field(..., pattern=r'^https?://.+')


class RecipeParseTextRequest(BaseModel):
    """Schema for text parsing request"""
    type: Literal["text"] = "text"
    text: str = Field(..., min_length=10, max_length=50000)


class RecipeParseImageRequest(BaseModel):
    """Schema for image parsing request"""
    type: Literal["image"] = "image"
    images: List[str] = Field(..., description="List of base64 encoded images", min_items=1, max_items=5)


class RecipeParseResponse(BaseModel):
    """Schema for recipe parsing response"""
    recipe: RecipeBase
    confidence: float = Field(..., ge=0.0, le=1.0)
    warnings: List[str] = Field(default_factory=list)


# ===== Cooking Session Schemas =====

class Command(BaseModel):
    """Universal command structure that AI can issue for various actions"""
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    command_type: Literal["timer"]  # Extensible to add more types later
    action: str  # The specific action to take
    target_id: Optional[str] = None  # ID of the target entity (e.g., timer_id)
    label: str
    parameters: Dict[str, Any] = Field(default_factory=dict)  # Flexible parameters
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))

    @field_serializer('created_at')
    def serialize_created_at(self, dt: datetime, _info):
        """Serialize datetime to ISO8601 format with timezone"""
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.isoformat()


class TimerStatus(BaseModel):
    """Current status of a timer (reported by frontend)"""
    id: str
    label: str
    duration_seconds: int
    status: Literal["pending", "running", "paused", "completed", "stopped"]
    remaining_seconds: int
    created_at: datetime
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None

    @field_serializer('created_at', 'started_at', 'completed_at')
    def serialize_datetime(self, dt: Optional[datetime], _info):
        """Serialize datetime to ISO8601 format with timezone"""
        if dt is None:
            return None
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.isoformat()


class Message(BaseModel):
    """Schema for conversation messages"""
    id: uuid.UUID = Field(default_factory=uuid.uuid4)
    role: Literal["user", "assistant"]
    content: str
    timestamp: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))

    @field_serializer('timestamp')
    def serialize_timestamp(self, dt: datetime, _info):
        """Serialize datetime to ISO8601 format with timezone"""
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.isoformat()


class CookingSessionBase(BaseModel):
    """Base cooking session schema"""
    recipe: RecipeBase
    commands: List[Command] = Field(default_factory=list)
    timer_status: List[TimerStatus] = Field(default_factory=list)
    conversation_history: List[Message] = Field(default_factory=list)
    user_preferences: UserPreferencesDetailed = Field(default_factory=UserPreferencesDetailed)
    started_at: datetime = Field(default_factory=datetime.now)


class AgentQueryRequest(BaseModel):
    """Schema for agent query request"""
    cooking_session: CookingSessionBase
    query: str = Field(..., min_length=1, max_length=1000)


class AgentQueryResponse(BaseModel):
    """Schema for agent query response"""
    response: str
    updated_session: CookingSessionBase
    audio: Optional[str] = Field(None, description="Base64 encoded MP3 audio (if ElevenLabs enabled)")
