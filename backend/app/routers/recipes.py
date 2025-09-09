"""
Recipe management and parsing routes
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from typing import List

from app.database import get_db
from app.schemas import (
    RecipeCreate, RecipeUpdate, RecipeResponse, RecipeListResponse,
    RecipeParseUrlRequest, RecipeParseTextRequest, RecipeParseImageRequest, 
    RecipeParseResponse
)
from app.crud import recipe_crud
from app.security import get_current_user_id
from app.services.recipe_parser import RecipeParser, RecipeParsingError

router = APIRouter(prefix="/recipes", tags=["recipes"])

# Initialize recipe parser (lazy initialization of OpenAI client)
recipe_parser = RecipeParser()


# ===== Recipe CRUD Endpoints =====

@router.get("/", response_model=List[RecipeListResponse])
async def get_user_recipes(
    current_user_id: str = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """Get all recipes for the current user"""
    recipes = recipe_crud.get_user_recipes(db, current_user_id)
    
    # Convert to response format
    return [
        RecipeListResponse(
            id=recipe.id,
            recipe_data=recipe.recipe_data,
            created_at=recipe.created_at,
            updated_at=recipe.updated_at
        )
        for recipe in recipes
    ]


@router.get("/{recipe_id}", response_model=RecipeResponse)
async def get_recipe(
    recipe_id: str,
    current_user_id: str = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """Get a specific recipe by ID"""
    recipe = recipe_crud.get_recipe(db, recipe_id, current_user_id)
    
    if not recipe:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Recipe not found"
        )
    
    return RecipeResponse(
        id=recipe.id,
        created_at=recipe.created_at,
        updated_at=recipe.updated_at,
        **recipe.recipe_data
    )


@router.post("/", response_model=RecipeResponse, status_code=status.HTTP_201_CREATED)
async def create_recipe(
    recipe: RecipeCreate,
    current_user_id: str = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """Create a new recipe"""
    try:
        db_recipe = recipe_crud.create_recipe(db, recipe, current_user_id)
        
        return RecipeResponse(
            id=db_recipe.id,
            created_at=db_recipe.created_at,
            updated_at=db_recipe.updated_at,
            **db_recipe.recipe_data
        )
        
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(e)
        )


@router.put("/{recipe_id}", response_model=RecipeResponse)
async def update_recipe(
    recipe_id: str,
    recipe_update: RecipeUpdate,
    current_user_id: str = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """Update an existing recipe"""
    
    # Check if recipe exists and belongs to user
    existing_recipe = recipe_crud.get_recipe(db, recipe_id, current_user_id)
    if not existing_recipe:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Recipe not found"
        )
    
    try:
        updated_recipe = recipe_crud.update_recipe(db, recipe_id, recipe_update)
        
        return RecipeResponse(
            id=updated_recipe.id,
            created_at=updated_recipe.created_at,
            updated_at=updated_recipe.updated_at,
            **updated_recipe.recipe_data
        )
        
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=str(e)
        )


@router.delete("/{recipe_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_recipe(
    recipe_id: str,
    current_user_id: str = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """Delete a recipe"""
    
    # Check if recipe exists and belongs to user
    existing_recipe = recipe_crud.get_recipe(db, recipe_id, current_user_id)
    if not existing_recipe:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Recipe not found"
        )
    
    success = recipe_crud.delete_recipe(db, recipe_id)
    if not success:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to delete recipe"
        )


# ===== Recipe Parsing Endpoints =====

@router.post("/parse/url", response_model=RecipeParseResponse)
async def parse_recipe_from_url(
    request: RecipeParseUrlRequest,
    current_user_id: str = Depends(get_current_user_id)
):
    """Parse a recipe from a URL"""
    try:
        result = await recipe_parser.parse_from_url(request.url)
        return result
        
    except RecipeParsingError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Recipe parsing failed: {str(e)}"
        )
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Internal server error during recipe parsing"
        )


@router.post("/parse/text", response_model=RecipeParseResponse)
async def parse_recipe_from_text(
    request: RecipeParseTextRequest,
    current_user_id: str = Depends(get_current_user_id)
):
    """Parse a recipe from plain text"""
    try:
        result = await recipe_parser.parse_from_text(request.text)
        return result
        
    except RecipeParsingError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Recipe parsing failed: {str(e)}"
        )
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Internal server error during recipe parsing"
        )


@router.post("/parse/image", response_model=RecipeParseResponse)
async def parse_recipe_from_image(
    request: RecipeParseImageRequest,
    current_user_id: str = Depends(get_current_user_id)
):
    """Parse a recipe from an image using GPT-4 Vision"""
    try:
        result = await recipe_parser.parse_from_image(request.image)
        return result
        
    except RecipeParsingError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Recipe parsing failed: {str(e)}"
        )
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Internal server error during recipe parsing"
        )


# ===== Utility Endpoints =====

@router.get("/search", response_model=List[RecipeListResponse])
async def search_recipes(
    q: str,
    current_user_id: str = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """Search recipes by title, ingredients, or tags"""
    if len(q.strip()) < 2:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Search query must be at least 2 characters"
        )
    
    recipes = recipe_crud.search_recipes(db, current_user_id, q)
    
    return [
        RecipeListResponse(
            id=recipe.id,
            recipe_data=recipe.recipe_data,
            created_at=recipe.created_at,
            updated_at=recipe.updated_at
        )
        for recipe in recipes
    ]


@router.get("/tags", response_model=List[str])
async def get_recipe_tags(
    current_user_id: str = Depends(get_current_user_id),
    db: Session = Depends(get_db)
):
    """Get all unique tags from user's recipes"""
    tags = recipe_crud.get_user_recipe_tags(db, current_user_id)
    return sorted(tags)
