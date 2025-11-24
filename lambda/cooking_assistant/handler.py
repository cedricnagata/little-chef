"""
AWS Lambda handler for cooking assistant
Accepts cooking session + query, returns response + updated session + optional audio
"""

import json
import base64
import logging
import os
from typing import Dict, Any

import sys
sys.path.append(os.path.join(os.path.dirname(__file__), '..'))

from shared.schemas import CookingSessionBase, AgentQueryRequest, AgentQueryResponse
from cooking_agent import cooking_agent
from elevenlabs_service import elevenlabs_service, ElevenLabsError

# Set up logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)


async def process_cooking_query(event_body: Dict[str, Any]) -> Dict[str, Any]:
    """
    Process cooking query with agent and optional TTS

    Args:
        event_body: Dictionary containing cooking_session and query

    Returns:
        Dictionary with response, updated_session, and optional audio (base64)
    """
    try:
        # Parse and validate request
        request = AgentQueryRequest(**event_body)

        logger.info(f"Processing query: '{request.query[:50]}...' for recipe: {request.cooking_session.recipe.title}")

        # Process query with cooking agent
        agent_result = await cooking_agent.process_query(
            request.cooking_session,
            request.query
        )

        response_text = agent_result["response"]
        updated_session = agent_result["updated_session"]

        # Check if ElevenLabs TTS is enabled in user preferences
        elevenlabs_settings = updated_session.user_preferences.voice_settings.elevenlabs
        audio_base64 = None

        if elevenlabs_settings.enabled:
            try:
                logger.info(f"ElevenLabs enabled, generating TTS with voice: {elevenlabs_settings.voice_name}")
                audio_bytes = await elevenlabs_service.text_to_speech(
                    text=response_text,
                    voice_settings=elevenlabs_settings
                )
                audio_base64 = base64.b64encode(audio_bytes).decode('utf-8')
                logger.info(f"Successfully generated TTS audio ({len(audio_bytes)} bytes)")
            except ElevenLabsError as e:
                logger.warning(f"ElevenLabs TTS failed, continuing without audio: {str(e)}")
            except Exception as e:
                logger.warning(f"Unexpected error during TTS, continuing without audio: {str(e)}")
        else:
            logger.info("ElevenLabs not enabled, skipping TTS generation")

        # Prepare response
        response_data = {
            "response": response_text,
            "updated_session": updated_session.model_dump(),
        }

        # Add audio if generated
        if audio_base64:
            response_data["audio"] = audio_base64

        logger.info(f"Successfully processed query, audio included: {audio_base64 is not None}")
        return response_data

    except Exception as e:
        logger.error(f"Error processing cooking query: {str(e)}", exc_info=True)
        raise


def lambda_handler(event, context):
    """
    AWS Lambda handler function

    Expected event body:
    {
        "cooking_session": CookingSessionBase,
        "query": str
    }

    Returns:
    {
        "statusCode": 200,
        "body": {
            "response": str,
            "updated_session": CookingSessionBase,
            "audio": str (optional, base64 encoded MP3)
        }
    }
    """
    try:
        # Log request
        logger.info("=== Cooking Assistant Lambda Invoked ===")
        logger.info(f"Event: {json.dumps(event, default=str)[:500]}...")

        # Parse request body
        if isinstance(event.get('body'), str):
            body = json.loads(event['body'])
        else:
            body = event.get('body', event)

        # Import asyncio and run async handler
        import asyncio

        # Process the query
        result = asyncio.run(process_cooking_query(body))

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
