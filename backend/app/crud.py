"""
CRUD operations for database models
"""

from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError
from sqlalchemy import or_, func
from typing import Optional, Dict, Any, List
import uuid

from app.models import User, Recipe
from app.schemas import UserCreate, UserUpdate, UserPreferences, RecipeCreate, RecipeUpdate
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
            
            # Delete the user (CASCADE will handle related recipes)
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


class RecipeCRUD:
    """CRUD operations for Recipe model"""
    
    def get_recipe(self, db: Session, recipe_id: str, user_id: str) -> Optional[Recipe]:
        """Get recipe by ID for a specific user"""
        try:
            recipe_uuid = uuid.UUID(recipe_id)
            user_uuid = uuid.UUID(user_id)
            return db.query(Recipe).filter(
                Recipe.id == recipe_uuid, 
                Recipe.user_id == user_uuid
            ).first()
        except ValueError:
            return None
    
    def get_user_recipes(self, db: Session, user_id: str, skip: int = 0, limit: int = 100) -> List[Recipe]:
        """Get all recipes for a user"""
        try:
            user_uuid = uuid.UUID(user_id)
            return db.query(Recipe).filter(
                Recipe.user_id == user_uuid
            ).order_by(Recipe.updated_at.desc()).offset(skip).limit(limit).all()
        except ValueError:
            return []
    
    def create_recipe(self, db: Session, recipe: RecipeCreate, user_id: str) -> Recipe:
        """Create a new recipe"""
        try:
            user_uuid = uuid.UUID(user_id)
            
            # Convert recipe to dict for JSONB storage
            recipe_data = recipe.model_dump()
            
            db_recipe = Recipe(
                user_id=user_uuid,
                recipe_data=recipe_data
            )
            
            db.add(db_recipe)
            db.commit()
            db.refresh(db_recipe)
            return db_recipe
            
        except ValueError as e:
            db.rollback()
            raise ValueError(f"Invalid user ID: {str(e)}")
        except IntegrityError as e:
            db.rollback()
            raise ValueError(f"Database error: {str(e)}")
    
    def update_recipe(self, db: Session, recipe_id: str, recipe_update: RecipeUpdate) -> Optional[Recipe]:
        """Update an existing recipe"""
        try:
            recipe_uuid = uuid.UUID(recipe_id)
            db_recipe = db.query(Recipe).filter(Recipe.id == recipe_uuid).first()
            
            if not db_recipe:
                return None
            
            # Get current recipe data
            current_data = db_recipe.recipe_data.copy()
            
            # Update with new data (only non-None values)
            update_data = recipe_update.model_dump(exclude_none=True)
            current_data.update(update_data)
            
            # Update the recipe data
            db_recipe.recipe_data = current_data
            
            # Mark the JSONB field as modified
            from sqlalchemy.orm.attributes import flag_modified
            flag_modified(db_recipe, 'recipe_data')
            
            db.commit()
            db.refresh(db_recipe)
            return db_recipe
            
        except ValueError:
            return None
    
    def delete_recipe(self, db: Session, recipe_id: str) -> bool:
        """Delete a recipe"""
        try:
            recipe_uuid = uuid.UUID(recipe_id)
            db_recipe = db.query(Recipe).filter(Recipe.id == recipe_uuid).first()
            
            if not db_recipe:
                return False
            
            db.delete(db_recipe)
            db.commit()
            return True
            
        except ValueError:
            return False
    
    def search_recipes(self, db: Session, user_id: str, query: str, skip: int = 0, limit: int = 50) -> List[Recipe]:
        """Search recipes by title, ingredients, or tags"""
        try:
            user_uuid = uuid.UUID(user_id)
            
            # Create search filter for JSONB fields
            search_filter = or_(
                # Search in title
                func.lower(Recipe.recipe_data['title'].astext).contains(query.lower()),
                # Search in ingredients (array of strings)
                Recipe.recipe_data['ingredients'].astext.ilike(f'%{query}%'),
                # Search in tags (array of strings)
                Recipe.recipe_data['tags'].astext.ilike(f'%{query}%'),
                # Search in cuisine_type
                func.lower(Recipe.recipe_data['cuisine_type'].astext).contains(query.lower())
            )
            
            return db.query(Recipe).filter(
                Recipe.user_id == user_uuid,
                search_filter
            ).order_by(Recipe.updated_at.desc()).offset(skip).limit(limit).all()
            
        except ValueError:
            return []
    
    def get_user_recipe_tags(self, db: Session, user_id: str) -> List[str]:
        """Get all unique tags from user's recipes"""
        try:
            user_uuid = uuid.UUID(user_id)
            
            # Query to extract all tags from recipes
            recipes = db.query(Recipe).filter(Recipe.user_id == user_uuid).all()
            
            # Extract unique tags
            all_tags = set()
            for recipe in recipes:
                tags = recipe.recipe_data.get('tags', [])
                if isinstance(tags, list):
                    all_tags.update(tag.lower().strip() for tag in tags if tag)
            
            return list(all_tags)
            
        except ValueError:
            return []


# Global CRUD instances
user_crud = UserCRUD()
recipe_crud = RecipeCRUD()
