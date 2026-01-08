"""
Recipe modification tools for cooking assistant
These tools allow the AI to suggest recipe modifications during cooking sessions
"""

import logging
from langchain_core.tools import tool
from pydantic import BaseModel, Field
from typing import List, Optional

logger = logging.getLogger()


# ===== Tool Input Schemas =====

class EditRecipeInput(BaseModel):
    """Input for editing the recipe during cooking session"""
    title: Optional[str] = Field(default=None, description="New recipe title (if changing)")
    description: Optional[str] = Field(default=None, description="New description (if changing)")
    servings: Optional[int] = Field(default=None, description="New servings count (if changing)")
    prep_time: Optional[int] = Field(default=None, description="New prep time in minutes (if changing)")
    cook_time: Optional[int] = Field(default=None, description="New cook time in minutes (if changing)")
    ingredients: Optional[List[str]] = Field(default=None, description="Complete new ingredients list (if changing)")
    instructions: Optional[List[str]] = Field(default=None, description="Complete new instructions list (if changing)")
    tags: Optional[List[str]] = Field(default=None, description="New tags (if changing)")
    cuisine_type: Optional[str] = Field(default=None, description="New cuisine type (if changing)")
    difficulty: Optional[str] = Field(default=None, description="New difficulty (if changing)")
    modification_summary: str = Field(description="Brief summary of changes made for user review")


# ===== Tool Functions =====

def create_recipe_tools():
    """
    Create LangChain tool for recipe editing during cooking sessions

    Returns:
        List containing the edit_recipe tool
    """

    @tool("edit_recipe", args_schema=EditRecipeInput)
    def edit_recipe(
        modification_summary: str,
        title: Optional[str] = None,
        description: Optional[str] = None,
        servings: Optional[int] = None,
        prep_time: Optional[int] = None,
        cook_time: Optional[int] = None,
        ingredients: Optional[List[str]] = None,
        instructions: Optional[List[str]] = None,
        tags: Optional[List[str]] = None,
        cuisine_type: Optional[str] = None,
        difficulty: Optional[str] = None
    ) -> str:
        """
        Edit the recipe during the cooking session. Only provide fields that are changing.

        Use this when the user asks to modify the recipe in any way:
        - Substitute ingredients (e.g., "use olive oil instead of butter")
        - Adjust quantities (e.g., "double the garlic")
        - Scale servings (provide new servings AND scaled ingredients list)
        - Change cooking instructions (e.g., "bake at 400 instead of 350")
        - Add or remove ingredients/steps

        The modified recipe will replace the current recipe in the cooking session.
        At the end of the session, the user can save the changes.

        Args:
            modification_summary: Brief summary of what changed (shown to user)
            title: New title (optional)
            description: New description (optional)
            servings: New servings count (optional)
            prep_time: New prep time in minutes (optional)
            cook_time: New cook time in minutes (optional)
            ingredients: Complete new ingredients list (optional)
            instructions: Complete new instructions list (optional)
            tags: New tags (optional)
            cuisine_type: New cuisine type (optional)
            difficulty: New difficulty (optional)

        Returns:
            Success message with modification summary
        """
        logger.info(f"Recipe edit requested: {modification_summary}")

        # Return marker for tool result processing
        # iOS will receive the modified recipe fields via the session update
        return f"recipe_modified:{modification_summary}"

    return [edit_recipe]
