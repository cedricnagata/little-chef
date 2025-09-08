"""
CRUD operations for database models
"""

from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError
from typing import Optional, Dict, Any
import uuid

from app.models import User
from app.schemas import UserCreate, UserUpdate, UserPreferences
from app.security import get_password_hash, verify_password


class UserCRUD:
    """CRUD operations for User model"""
    
    def get_user(self, db: Session, user_id: str) -> Optional[User]:
        """Get user by ID"""
        try:
            user_uuid = uuid.UUID(user_id)
            return db.query(User).filter(User.id == user_uuid, User.is_active == True).first()
        except ValueError:
            return None
    
    def get_user_by_email(self, db: Session, email: str) -> Optional[User]:
        """Get user by email"""
        return db.query(User).filter(User.email == email, User.is_active == True).first()
    
    def create_user(self, db: Session, user: UserCreate) -> User:
        """Create a new user"""
        hashed_password = get_password_hash(user.password)
        
        # Create default preferences
        default_preferences = UserPreferences()
        preferences_dict = default_preferences.model_dump()
        
        db_user = User(
            email=user.email,
            name=user.name,
            hashed_password=hashed_password,
            preferences=preferences_dict
        )
        
        try:
            db.add(db_user)
            db.commit()
            db.refresh(db_user)
            return db_user
        except IntegrityError:
            db.rollback()
            raise ValueError("User with this email already exists")
    
    def update_user(self, db: Session, user_id: str, user_update: UserUpdate) -> Optional[User]:
        """Update user information"""
        try:
            user_uuid = uuid.UUID(user_id)
            db_user = db.query(User).filter(User.id == user_uuid, User.is_active == True).first()
            
            if not db_user:
                return None
            
            update_data = user_update.model_dump(exclude_none=True)
            
            for field, value in update_data.items():
                setattr(db_user, field, value)
            
            db.commit()
            db.refresh(db_user)
            return db_user
            
        except ValueError:
            return None
    
    def update_user_preferences(self, db: Session, user_id: str, preferences: Dict[str, Any]) -> Optional[User]:
        """Update user preferences"""
        try:
            user_uuid = uuid.UUID(user_id)
            db_user = db.query(User).filter(User.id == user_uuid, User.is_active == True).first()
            
            if not db_user:
                return None
            
            # Merge with existing preferences
            current_prefs = db_user.preferences or {}
            current_prefs.update(preferences)
            
            # Update the preferences
            db_user.preferences = current_prefs
            
            # Mark the JSONB field as modified so SQLAlchemy detects the change
            from sqlalchemy.orm.attributes import flag_modified
            flag_modified(db_user, 'preferences')
            
            try:
                db.commit()
                db.refresh(db_user)
                return db_user
            except Exception as e:
                db.rollback()
                return None
            
        except ValueError:
            db.rollback()
            return None
        except Exception:
            db.rollback()
            return None
    
    def verify_password(self, db: Session, user_id: str, password: str) -> bool:
        """Verify if the provided password matches the user's current password"""
        try:
            user_uuid = uuid.UUID(user_id)
            db_user = db.query(User).filter(User.id == user_uuid, User.is_active == True).first()
            
            if not db_user:
                return False
            
            # Verify password
            return verify_password(password, db_user.hashed_password)
            
        except ValueError:
            return False
    
    def change_password(self, db: Session, user_id: str, current_password: str, new_password: str) -> bool:
        """Change user password"""
        try:
            user_uuid = uuid.UUID(user_id)
            db_user = db.query(User).filter(User.id == user_uuid, User.is_active == True).first()
            
            if not db_user:
                return False
            
            # Verify current password
            if not verify_password(current_password, db_user.hashed_password):
                return False
            
            # Update to new password
            db_user.hashed_password = get_password_hash(new_password)
            db.commit()
            return True
            
        except ValueError:
            return False
    
    def delete_user(self, db: Session, user_id: str) -> bool:
        """Permanently delete user account and all associated data"""
        try:
            user_uuid = uuid.UUID(user_id)
            db_user = db.query(User).filter(User.id == user_uuid).first()
            
            if not db_user:
                return False
            
            # Delete the user (CASCADE will handle related recipes and cooking_sessions)
            db.delete(db_user)
            db.commit()
            return True
            
        except ValueError:
            return False
    
    def authenticate_user(self, db: Session, email: str, password: str) -> Optional[User]:
        """Authenticate user with email and password"""
        user = self.get_user_by_email(db, email)
        if not user:
            return None
        if not verify_password(password, user.hashed_password):
            return None
        return user


# Global CRUD instance
user_crud = UserCRUD()
