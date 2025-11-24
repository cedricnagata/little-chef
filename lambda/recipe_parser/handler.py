"""
AWS Lambda handler for recipe parsing
Accepts URL, text, or images and returns parsed recipe
"""

import json
import logging
import os
from typing import Dict, Any

import sys
sys.path.append(os.path.join(os.path.dirname(__file__), '..'))

from shared.schemas import RecipeParseUrlRequest, RecipeParseTextRequest, RecipeParseImageRequest
from recipe_parser import RecipeParser, RecipeParsingError

# Set up logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Create parser instance
recipe_parser = RecipeParser()


async def process_recipe_parse(event_body: Dict[str, Any]) -> Dict[str, Any]:
    """
    Process recipe parsing request

    Args:
        event_body: Dictionary containing parsing request with type and input

    Returns:
        Dictionary with recipe, confidence, and warnings
    """
    try:
        parse_type = event_body.get('type')

        if not parse_type:
            raise ValueError("Missing 'type' field. Must be one of: url, text, image")

        logger.info(f"Processing recipe parse request, type: {parse_type}")

        if parse_type == 'url':
            # Parse from URL
            request = RecipeParseUrlRequest(**event_body)
            logger.info(f"Parsing recipe from URL: {request.url}")
            result = await recipe_parser.parse_from_url(request.url)

        elif parse_type == 'text':
            # Parse from text
            request = RecipeParseTextRequest(**event_body)
            text_preview = request.text[:100] + "..." if len(request.text) > 100 else request.text
            logger.info(f"Parsing recipe from text: {text_preview}")
            result = await recipe_parser.parse_from_text(request.text)

        elif parse_type == 'image':
            # Parse from images
            request = RecipeParseImageRequest(**event_body)
            logger.info(f"Parsing recipe from {len(request.images)} image(s)")
            result = await recipe_parser.parse_from_image(request.images)

        else:
            raise ValueError(f"Invalid parse type '{parse_type}'. Must be one of: url, text, image")

        # Convert to dict for JSON serialization
        response_data = {
            "recipe": result.recipe.model_dump(),
            "confidence": result.confidence,
            "warnings": result.warnings
        }

        logger.info(f"Successfully parsed recipe: {result.recipe.title} (confidence: {result.confidence:.2f})")
        return response_data

    except RecipeParsingError as e:
        logger.error(f"Recipe parsing error: {str(e)}")
        raise
    except Exception as e:
        logger.error(f"Error processing recipe parse: {str(e)}", exc_info=True)
        raise


def lambda_handler(event, context):
    """
    AWS Lambda handler function

    Expected event body:
    {
        "type": "url" | "text" | "image",
        "url": str (if type=url),
        "text": str (if type=text),
        "images": [str] (if type=image, base64 encoded)
    }

    Returns:
    {
        "statusCode": 200,
        "body": {
            "recipe": RecipeBase,
            "confidence": float,
            "warnings": [str]
        }
    }
    """
    try:
        # Log request
        logger.info("=== Recipe Parser Lambda Invoked ===")
        logger.info(f"Event: {json.dumps(event, default=str)[:500]}...")

        # Parse request body
        if isinstance(event.get('body'), str):
            body = json.loads(event['body'])
        else:
            body = event.get('body', event)

        # Import asyncio and run async handler
        import asyncio

        # Process the parsing request
        result = asyncio.run(process_recipe_parse(body))

        # Return success response
        response = {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*",  # Configure CORS appropriately
                "Access-Control-Allow-Headers": "Content-Type,X-Api-Key",
                "Access-Control-Allow-Methods": "POST,OPTIONS"
            },
            "body": json.dumps(result, default=str)
        }

        logger.info("=== Lambda Execution Successful ===")
        return response

    except RecipeParsingError as e:
        logger.error(f"Recipe parsing error: {str(e)}")
        error_response = {
            "statusCode": 400,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Headers": "Content-Type,X-Api-Key",
                "Access-Control-Allow-Methods": "POST,OPTIONS"
            },
            "body": json.dumps({
                "error": "Recipe parsing failed",
                "message": str(e)
            })
        }
        return error_response

    except ValueError as e:
        logger.error(f"Validation error: {str(e)}")
        error_response = {
            "statusCode": 400,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Headers": "Content-Type,X-Api-Key",
                "Access-Control-Allow-Methods": "POST,OPTIONS"
            },
            "body": json.dumps({
                "error": "Invalid request",
                "message": str(e)
            })
        }
        return error_response

    except Exception as e:
        logger.error(f"Lambda handler error: {str(e)}", exc_info=True)
        error_response = {
            "statusCode": 500,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Headers": "Content-Type,X-Api-Key",
                "Access-Control-Allow-Methods": "POST,OPTIONS"
            },
            "body": json.dumps({
                "error": "Internal server error",
                "message": str(e)
            })
        }
        return error_response
