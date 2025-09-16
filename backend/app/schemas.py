"""
Pydantic schemas for request/response models
"""

from pydantic import BaseModel, EmailStr, Field, validator
from typing import Optional, Dict, Any, List, Literal
from datetime import datetime
import uuid


class UserBase(BaseModel):
    """Base user schema"""
    email: EmailStr
    name: str = Field(..., min_length=1, max_length=255)


class UserCreate(UserBase):
    """Schema for user registration"""
    password: str = Field(..., min_length=8, max_length=128)
    
    
    @validator('password')
    def validate_password(cls, v):
        """Validate password strength"""
        if len(v) < 8:
            raise ValueError('Password must be at least 8 characters long')
        return v


class UserLogin(BaseModel):
    """Schema for user login"""
    email: EmailStr
    password: str


class UserResponse(UserBase):
    """Schema for user response (excludes sensitive data)"""
    id: uuid.UUID
    is_active: bool
    preferences: Dict[str, Any]
    created_at: datetime
    updated_at: datetime
    
    class Config:
        from_attributes = True


class UserUpdate(BaseModel):
    """Schema for user updates"""
    name: Optional[str] = Field(None, min_length=1, max_length=255)
    email: Optional[EmailStr] = None
    preferences: Optional[Dict[str, Any]] = None
    
    class Config:
        # This ensures that None values are excluded from model_dump
        exclude_none = True


class UserPreferences(BaseModel):
    """Schema for user preferences"""
    llm_model: str = Field("gpt-4.1", pattern="^(gpt-5|gpt-5-mini|gpt-5-nano|gpt-4.1|gpt-4.1-mini|gpt-4.1-nano)$")
    measurement_system: str = Field("imperial", pattern="^(metric|imperial)$")
    dietary_restrictions: list[str] = Field(default_factory=list)
    voice_settings: Dict[str, Any] = Field(default_factory=dict)


class Token(BaseModel):
    """Schema for authentication token response"""
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int
    user: UserResponse


class TokenRefresh(BaseModel):
    """Schema for token refresh request"""
    refresh_token: str


class PasswordChange(BaseModel):
    """Schema for password change"""
    current_password: str
    new_password: str = Field(..., min_length=8, max_length=128)
    
    @validator('new_password')
    def validate_new_password(cls, v):
        """Validate new password strength"""
        if len(v) < 8:
            raise ValueError('Password must be at least 8 characters long')
        return v


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


class RecipeCreate(RecipeBase):
    """Schema for creating a new recipe"""
    pass


class RecipeUpdate(BaseModel):
    """Schema for updating an existing recipe"""
    title: Optional[str] = Field(None, min_length=1, max_length=255)
    description: Optional[str] = None
    servings: Optional[int] = Field(None, ge=1, le=100)
    prep_time: Optional[int] = Field(None, ge=0, le=1440)
    cook_time: Optional[int] = Field(None, ge=0, le=1440)
    ingredients: Optional[List[str]] = Field(None, min_items=1)
    instructions: Optional[List[str]] = Field(None, min_items=1)
    tags: Optional[List[str]] = None
    source_url: Optional[str] = None
    cuisine_type: Optional[str] = None
    difficulty: Optional[str] = Field(None, pattern="^(easy|medium|hard)$")

    class Config:
        exclude_none = True


class RecipeResponse(RecipeBase):
    """Schema for recipe response"""
    id: uuid.UUID
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


class RecipeListResponse(BaseModel):
    """Schema for recipe list response"""
    id: uuid.UUID
    recipe_data: RecipeBase
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


# ===== Recipe Parsing Schemas =====

class RecipeParseUrlRequest(BaseModel):
    """Schema for URL parsing request"""
    url: str = Field(..., pattern=r'^https?://.+')


class RecipeParseTextRequest(BaseModel):
    """Schema for text parsing request"""
    text: str = Field(..., min_length=10, max_length=50000)


class RecipeParseImageRequest(BaseModel):
    """Schema for image parsing request"""
    images: List[str] = Field(..., description="List of base64 encoded images", min_items=1, max_items=5)


class RecipeParseResponse(BaseModel):
    """Schema for recipe parsing response"""
    recipe: RecipeBase
    confidence: float = Field(..., ge=0.0, le=1.0)
    warnings: List[str] = Field(default_factory=list)


# ===== Recipe Modifications Schemas =====

class RecipeModifications(BaseModel):
    """Schema for recipe modifications"""
    serving_multiplier: float = Field(default=1.0, gt=0.0, le=10.0)
    ingredient_substitutions: Dict[str, str] = Field(default_factory=dict)
    notes: List[str] = Field(default_factory=list)


class Command(BaseModel):
    """Universal command structure that AI can issue for various actions"""
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    command_type: Literal["timer"]  # Extensible to add more types later
    action: str  # The specific action to take
    target_id: Optional[str] = None  # ID of the target entity (e.g., timer_id)
    label: str
    parameters: Dict[str, Any] = Field(default_factory=dict)  # Flexible parameters
    created_at: datetime = Field(default_factory=datetime.now)

# Legacy alias for backward compatibility during transition
TimerCommand = Command


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


class Message(BaseModel):
    """Schema for conversation messages"""
    id: uuid.UUID = Field(default_factory=uuid.uuid4)
    role: Literal["user", "assistant"]
    content: str
    timestamp: datetime = Field(default_factory=datetime.now)


class VoiceSettings(BaseModel):
    """Schema for voice settings"""
    speech_rate: float = Field(default=0.5, ge=0.1, le=2.0)
    voice_identifier: str = Field(default="com.apple.ttsbundle.Samantha-compact")
    auto_speak_responses: bool = True


class UserPreferencesDetailed(UserPreferences):
    """Extended user preferences with voice settings"""
    voice_settings: VoiceSettings = Field(default_factory=VoiceSettings)


# ===== Cooking Session Schemas =====

class CookingSessionBase(BaseModel):
    """Base cooking session schema"""
    recipe: RecipeBase
    modifications: RecipeModifications = Field(default_factory=RecipeModifications)
    commands: List[Command] = Field(default_factory=list)
    timer_status: List[TimerStatus] = Field(default_factory=list)
    conversation_history: List[Message] = Field(default_factory=list)
    user_preferences: UserPreferencesDetailed = Field(default_factory=UserPreferencesDetailed)
    started_at: datetime = Field(default_factory=datetime.now)


class CookingSessionCreate(CookingSessionBase):
    """Schema for creating a cooking session"""
    pass


class CookingSessionResponse(CookingSessionBase):
    """Schema for cooking session response"""
    id: uuid.UUID

    class Config:
        from_attributes = True


class AgentQueryRequest(BaseModel):
    """Schema for agent query request"""
    cooking_session: CookingSessionBase
    query: str = Field(..., min_length=1, max_length=1000)


class SuggestedAction(BaseModel):
    """Schema for suggested actions from agent"""
    type: str
    description: str


class AgentQueryResponse(BaseModel):
    """Schema for agent query response"""
    response: str
    updated_session: CookingSessionBase
    suggested_actions: List[SuggestedAction] = Field(default_factory=list)
