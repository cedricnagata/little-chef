"""
Recipe Editor Lambda Handler
Provides AI-powered recipe editing with granular change tracking
"""

import json
import logging
import os
import asyncio
from typing import List, Dict, Any

from langchain_openai import ChatOpenAI
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import PydanticOutputParser

# Import from shared layer
import sys
sys.path.append('/opt/python')
from shared.schemas import (
    RecipeEditRequest,
    RecipeEditResponse,
    RecipeModification,
    RecipeBase
)
from prompts import RECIPE_EDITING_PROMPT

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Get OpenAI API key from environment
OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY")
if not OPENAI_API_KEY:
    raise ValueError("OPENAI_API_KEY environment variable is required")


async def process_recipe_edit(request: RecipeEditRequest) -> RecipeEditResponse:
    """
    Process recipe editing request using LLM

    Args:
        request: RecipeEditRequest containing recipe and edit instructions

    Returns:
        RecipeEditResponse with granular modifications list
    """
    logger.info(f"Processing recipe edit request for: {request.recipe.title}")
    logger.info(f"Edit instructions: {request.edit_instructions}")

    # Build prompt with recipe context (simple numbered list for readability)
    ingredients_text = "\n".join(f"- {ing}" for ing in request.recipe.ingredients)
    instructions_text = "\n".join(f"{i+1}. {inst}" for i, inst in enumerate(request.recipe.instructions))

    # Prepare dietary restrictions text
    dietary_restrictions = ", ".join(request.user_preferences.dietary_restrictions) if request.user_preferences.dietary_restrictions else "None"

    # Prepare tags text
    tags_text = ", ".join(request.recipe.tags) if request.recipe.tags else "None"

    # Setup parser
    parser = PydanticOutputParser(pydantic_object=RecipeEditResponse)

    # Create prompt template
    prompt = ChatPromptTemplate.from_template(RECIPE_EDITING_PROMPT)

    # Format prompt with recipe details
    formatted_prompt = prompt.format(
        recipe_title=request.recipe.title,
        servings=request.recipe.servings,
        prep_time=request.recipe.prep_time or "Not specified",
        cook_time=request.recipe.cook_time or "Not specified",
        description=request.recipe.description or "None",
        tags=tags_text,
        cuisine_type=request.recipe.cuisine_type or "Not specified",
        difficulty=request.recipe.difficulty or "medium",
        ingredients=ingredients_text,
        instructions=instructions_text,
        edit_instructions=request.edit_instructions,
        measurement_system=request.user_preferences.measurement_system,
        dietary_restrictions=dietary_restrictions,
        format_instructions=parser.get_format_instructions()
    )

    logger.info("Calling LLM for recipe modifications...")

    # Initialize LLM
    llm_model = request.user_preferences.llm_model
    # Map to actual OpenAI model names
    model_mapping = {
        "gpt-4.1": "gpt-4-turbo-preview",
        "gpt-4.1-mini": "gpt-4-turbo-preview",  # Use same for now
        "gpt-4.1-nano": "gpt-3.5-turbo"
    }
    actual_model = model_mapping.get(llm_model, "gpt-4-turbo-preview")

    llm = ChatOpenAI(
        model=actual_model,
        temperature=0.1,  # Low temperature for consistent modifications
        api_key=OPENAI_API_KEY
    )

    # Create chain
    chain = prompt | llm | parser

    try:
        # Invoke chain
        result = await chain.ainvoke({
            "recipe_title": request.recipe.title,
            "servings": request.recipe.servings,
            "prep_time": request.recipe.prep_time or "Not specified",
            "cook_time": request.recipe.cook_time or "Not specified",
            "description": request.recipe.description or "None",
            "tags": tags_text,
            "cuisine_type": request.recipe.cuisine_type or "Not specified",
            "difficulty": request.recipe.difficulty or "medium",
            "ingredients": ingredients_text,
            "instructions": instructions_text,
            "edit_instructions": request.edit_instructions,
            "measurement_system": request.user_preferences.measurement_system,
            "dietary_restrictions": dietary_restrictions,
            "format_instructions": parser.get_format_instructions()
        })

        logger.info(f"LLM returned modified recipe: {result.modified_recipe.title}")
        logger.info(f"Overall confidence: {result.overall_confidence:.2f}")
        logger.info(f"Warnings: {len(result.warnings)}")

        return result

    except Exception as e:
        logger.error(f"Error processing recipe edit: {str(e)}", exc_info=True)
        # Return response with error
        return RecipeEditResponse(
            modified_recipe=request.recipe,
            overall_confidence=0.0,
            warnings=[f"Error processing modifications: {str(e)}"]
        )


def lambda_handler(event, context):
    """
    AWS Lambda handler for recipe editing

    Args:
        event: API Gateway event
        context: Lambda context

    Returns:
        API Gateway response
    """
    logger.info("Recipe editor Lambda invoked")

    try:
        # Parse request body
        body = json.loads(event.get('body', '{}'))
        logger.info(f"Received request body: {json.dumps(body, default=str)[:200]}...")

        # Create request object
        request = RecipeEditRequest(**body)

        # Process recipe edit
        result = asyncio.run(process_recipe_edit(request))

        # Return success response
        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Headers": "Content-Type,X-Api-Key",
                "Access-Control-Allow-Methods": "POST,OPTIONS"
            },
            "body": json.dumps(result.model_dump(), default=str)
        }

    except Exception as e:
        logger.error(f"Error in lambda_handler: {str(e)}", exc_info=True)
        return {
            "statusCode": 500,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*"
            },
            "body": json.dumps({
                "error": str(e),
                "message": "Failed to process recipe edit request"
            })
        }
