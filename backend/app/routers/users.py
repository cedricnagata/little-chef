"""
User management routes for profile updates and preferences
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.database import get_db
from app.schemas import UserResponse, UserUpdate, UserPreferences
from app.crud import user_crud
from app.security import get_current_user_id

router = APIRouter(prefix="/users", tags=["users"])


@router.put("/profile", response_model=UserResponse)
async def update_profile(
    user_update: UserUpdate,
    current_user_id: str = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """Update user profile information"""
    
    updated_user = user_crud.update_user(db, current_user_id, user_update)
    if not updated_user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )
    
    return UserResponse.model_validate(updated_user)


@router.put("/preferences", response_model=UserResponse)
async def update_preferences(
    preferences: UserPreferences,
    current_user_id: str = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """Update user preferences"""
    
    # Convert Pydantic model to dict
    preferences_dict = preferences.model_dump()
    
    updated_user = user_crud.update_user_preferences(db, current_user_id, preferences_dict)
    if not updated_user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )
    
    return UserResponse.model_validate(updated_user)


@router.get("/preferences", response_model=UserPreferences)
async def get_preferences(
    current_user_id: str = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """Get user preferences"""
    
    user = user_crud.get_user(db, current_user_id)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )
    
    # Return preferences with defaults for missing values
    preferences = user.preferences or {}
    
    return UserPreferences(
        llm_model=preferences.get("llm_model", "gpt-4.1"),
        measurement_system=preferences.get("measurement_system", "imperial"),
        dietary_restrictions=preferences.get("dietary_restrictions", []),
        voice_settings=preferences.get("voice_settings", {})
    )
