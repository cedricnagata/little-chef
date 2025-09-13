"""
Agent tools for cooking knowledge and assistance.
"""

from langchain_openai import ChatOpenAI
from langchain_core.prompts import ChatPromptTemplate

from app.config import settings
from app.schemas import RecipeBase, RecipeModifications
from app.prompts import get_cooking_prompts
import re


class KnowledgeTools:
    """Tools for cooking knowledge and advice"""
    
    def __init__(self):
        self._llm_cache = {}
    
    def _get_llm(self, model_name: str) -> ChatOpenAI:
        """Get or create LLM instance with caching"""
        if model_name not in self._llm_cache:
            self._llm_cache[model_name] = ChatOpenAI(
                model=model_name,
                temperature=0.1,
                verbosity="low",
                openai_api_key=settings.openai_api_key
            )
        
        return self._llm_cache[model_name]
    
    def _apply_recipe_modifications(self, recipe: RecipeBase, modifications: RecipeModifications) -> RecipeBase:
        """Apply recipe modifications to create a modified recipe for context"""
        try:
            # Start with the original recipe
            modified_ingredients = []
            
            # Apply serving multiplier to ingredients
            serving_multiplier = modifications.serving_multiplier
            
            for ingredient in recipe.ingredients:
                modified_ingredient = self._scale_ingredient(ingredient, serving_multiplier)
                # Apply any ingredient substitutions
                for original, substitute in modifications.ingredient_substitutions.items():
                    modified_ingredient = modified_ingredient.replace(original, substitute)
                modified_ingredients.append(modified_ingredient)
            
            # Calculate new serving count
            new_servings = int(recipe.servings * serving_multiplier)
            
            # Create modified recipe (we can't modify the original RecipeBase since it's immutable)
            # So we'll create a new one with the modifications applied
            from copy import deepcopy
            modified_recipe_dict = {
                "title": recipe.title,
                "description": recipe.description,
                "servings": new_servings,
                "prep_time": recipe.prep_time,
                "cook_time": recipe.cook_time,
                "ingredients": modified_ingredients,
                "instructions": recipe.instructions,
                "tags": recipe.tags,
                "source_url": recipe.source_url,
                "cuisine_type": recipe.cuisine_type,
                "difficulty": recipe.difficulty
            }
            
            # Return a new RecipeBase with modifications applied
            return RecipeBase(**modified_recipe_dict)
            
        except Exception as e:
            # If modification fails, return original recipe
            print(f"Error applying recipe modifications: {e}")
            return recipe
    
    def _scale_ingredient(self, ingredient: str, multiplier: float) -> str:
        """Scale ingredient quantities by multiplier"""
        if multiplier == 1.0:
            return ingredient
            
        # Common patterns for numbers in ingredients
        # Examples: "2 cups flour", "1/2 teaspoon salt", "1.5 pounds chicken"
        patterns = [
            r'(\d+\.?\d*\/?\d*)\s+(\w+)',  # "2 cups", "1/2 teaspoon"
            r'(\d+\.?\d*)\s+(\w+)',       # "1.5 pounds"
            r'(\d+)\s+(\w+)'              # "2 cups"
        ]
        
        for pattern in patterns:
            match = re.search(pattern, ingredient)
            if match:
                try:
                    # Extract the number and unit
                    amount_str = match.group(1)
                    
                    # Handle fractions like "1/2"
                    if '/' in amount_str:
                        parts = amount_str.split('/')
                        amount = float(parts[0]) / float(parts[1])
                    else:
                        amount = float(amount_str)
                    
                    # Scale the amount
                    scaled_amount = amount * multiplier
                    
                    # Format the scaled amount nicely
                    if scaled_amount == int(scaled_amount):
                        scaled_str = str(int(scaled_amount))
                    else:
                        scaled_str = f"{scaled_amount:.2f}".rstrip('0').rstrip('.')
                    
                    # Replace in the original string
                    return ingredient.replace(amount_str, scaled_str, 1)
                except (ValueError, ZeroDivisionError):
                    continue
        
        # If no number pattern found, return original ingredient with note
        if multiplier != 1.0:
            return f"{ingredient} (scale by {multiplier:.1f}x)"
        return ingredient
    
    async def get_cooking_knowledge(self, query: str, recipe_context: RecipeBase, modifications: RecipeModifications, conversation_history: list, model: str) -> str:
        """Get cooking knowledge relevant to the query and recipe"""
        try:
            llm = self._get_llm(model)
            
            # Apply modifications to get the actual recipe being cooked
            modified_recipe = self._apply_recipe_modifications(recipe_context, modifications)
            
            # Build context about the recipe (using modified version)
            context = f"Recipe: {modified_recipe.title}\n"
            context += f"Servings: {modified_recipe.servings}\n"
            context += f"Cuisine: {modified_recipe.cuisine_type or 'General'}\n"
            context += f"Ingredients: {', '.join(modified_recipe.ingredients[:5])}\n"
            if len(modified_recipe.ingredients) > 5:
                context += f"...and {len(modified_recipe.ingredients) - 5} more ingredients\n"
            context += f"Cooking time: {modified_recipe.cook_time or 'Not specified'} minutes\n"
            context += f"Difficulty: {modified_recipe.difficulty or 'Not specified'}"
            
            # Add modification info if applicable
            if modifications.serving_multiplier != 1.0:
                context += f"\n\nNote: Recipe has been scaled by {modifications.serving_multiplier:.1f}x from original {recipe_context.servings} servings to {modified_recipe.servings} servings."
            
            # Build conversation history context
            conversation_context = ""
            if conversation_history and len(conversation_history) > 0:
                conversation_context = "\n\nPrevious conversation:\n"
                # Include the last 10 messages to avoid token limits but maintain context
                recent_messages = conversation_history[-10:] if len(conversation_history) > 10 else conversation_history
                for message in recent_messages:
                    role = "User" if message.role == "user" else "Assistant"
                    conversation_context += f"{role}: {message.content}\n"
            
            prompt = ChatPromptTemplate.from_messages([
                ("system", get_cooking_prompts()["knowledge_system"]),
                ("human", get_cooking_prompts()["knowledge_template"].format(
                    context=context + conversation_context,
                    query=query
                ))
            ])
            
            chain = prompt | llm
            response = await chain.ainvoke({})
            
            return response.content
            
        except Exception as e:
            return f"I'd love to help with that cooking question, but I'm having trouble accessing my knowledge right now. Could you try asking again? Error: {str(e)}"
