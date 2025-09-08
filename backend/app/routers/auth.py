"""
Authentication routes for user registration, login, and token management
"""

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPBearer
from sqlalchemy.orm import Session

from app.database import get_db
from app.schemas import UserCreate, UserLogin, UserResponse, Token, TokenRefresh, PasswordChange, UserUpdate
from app.crud import user_crud
from app.security import (
    create_access_token, 
    create_refresh_token, 
    verify_token, 
    get_current_user_id
)
from app.config import settings

router = APIRouter(prefix="/auth", tags=["authentication"])
security = HTTPBearer()


@router.post("/register", response_model=Token, status_code=status.HTTP_201_CREATED)
async def register_user(user: UserCreate, db: Session = Depends(get_db)):
    """Register a new user"""
    
    # Check if user already exists
    if user_crud.get_user_by_email(db, user.email):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="User with this email already exists"
        )
    
    try:
        # Create user
        db_user = user_crud.create_user(db, user)
        
        # Create tokens
        access_token = create_access_token(data={"sub": str(db_user.id)})
        refresh_token = create_refresh_token(data={"sub": str(db_user.id)})
        
        return Token(
            access_token=access_token,
            refresh_token=refresh_token,
            expires_in=settings.jwt_access_token_expire_minutes * 60,
            user=UserResponse.model_validate(db_user)
        )
        
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(e)
        )


@router.post("/login", response_model=Token)
async def login_user(user_login: UserLogin, db: Session = Depends(get_db)):
    """Authenticate user and return access token"""
    
    # Authenticate user
    user = user_crud.authenticate_user(db, user_login.email, user_login.password)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    
    # Check if user is active
    if not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User account is deactivated",
            headers={"WWW-Authenticate": "Bearer"},
        )
    
    # Create tokens
    access_token = create_access_token(data={"sub": str(user.id)})
    refresh_token = create_refresh_token(data={"sub": str(user.id)})
    
    return Token(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=settings.jwt_access_token_expire_minutes * 60,
        user=UserResponse.model_validate(user)
    )


@router.post("/refresh", response_model=Token)
async def refresh_token(token_refresh: TokenRefresh, db: Session = Depends(get_db)):
    """Refresh access token using refresh token"""
    
    # Verify refresh token
    payload = verify_token(token_refresh.refresh_token)
    if not payload or payload.get("type") != "refresh":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid refresh token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    
    user_id = payload.get("sub")
    if not user_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid refresh token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    
    # Get user from database
    user = user_crud.get_user(db, user_id)
    if not user or not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="User not found or inactive",
            headers={"WWW-Authenticate": "Bearer"},
        )
    
    # Create new tokens
    access_token = create_access_token(data={"sub": str(user.id)})
    new_refresh_token = create_refresh_token(data={"sub": str(user.id)})
    
    return Token(
        access_token=access_token,
        refresh_token=new_refresh_token,
        expires_in=settings.jwt_access_token_expire_minutes * 60,
        user=UserResponse.model_validate(user)
    )


@router.post("/logout", status_code=status.HTTP_200_OK)
async def logout_user(current_user_id: str = Depends(get_current_user_id)):
    """Logout user (client should discard tokens)"""
    return {"message": "Successfully logged out"}


@router.get("/me", response_model=UserResponse)
async def get_current_user_info(
    current_user_id: str = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """Get current user information"""
    user = user_crud.get_user(db, current_user_id)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )
    
    return UserResponse.model_validate(user)


@router.put("/profile", response_model=UserResponse)
async def update_profile(
    user_update: UserUpdate,
    current_user_id: str = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """Update user profile information"""
    
    # Check if email is being updated and if it already exists
    email_to_update = getattr(user_update, 'email', None)
    if email_to_update:
        existing_user = user_crud.get_user_by_email(db, email_to_update)
        if existing_user and str(existing_user.id) != current_user_id:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="User with this email already exists"
            )
    
    updated_user = user_crud.update_user(db, current_user_id, user_update)
    
    if not updated_user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )
    
    return UserResponse.model_validate(updated_user)


@router.post("/verify-password", status_code=status.HTTP_200_OK)
async def verify_password(
    password_verification: dict,
    current_user_id: str = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """Verify if the current password is correct"""
    
    current_password = password_verification.get("current_password")
    if not current_password:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Current password is required"
        )
    
    is_valid = user_crud.verify_password(db, current_user_id, current_password)
    
    if not is_valid:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Current password is incorrect"
        )
    
    return {"message": "Password verified successfully"}


@router.post("/change-password", status_code=status.HTTP_200_OK)
async def change_password(
    password_change: PasswordChange,
    current_user_id: str = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """Change user password"""
    
    success = user_crud.change_password(
        db, 
        current_user_id, 
        password_change.current_password, 
        password_change.new_password
    )
    
    if not success:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Current password is incorrect"
        )
    
    return {"message": "Password changed successfully"}


@router.delete("/delete-account", status_code=status.HTTP_204_NO_CONTENT)
async def delete_account(
    current_user_id: str = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """Permanently delete user account and all associated data"""
    
    success = user_crud.delete_user(db, current_user_id)
    if not success:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found"
        )
    
    # No content returned for 204 status


