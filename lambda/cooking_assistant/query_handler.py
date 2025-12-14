"""
Query Handler for Cooking Assistant

Processes cooking queries with streaming tokens and audio.
"""

import logging
from typing import Dict, Any
from shared.schemas import CookingSessionBase
from websocket_sender import WebSocketSender
from cooking_agent import cooking_agent
from polly_service import PollyService

logger = logging.getLogger(__name__)


async def handle_query(body: Dict[str, Any], sender: WebSocketSender) -> None:
    """
    Handle cooking assistant query with streaming tokens + audio.

    Args:
        body: Request body containing payload with cooking_session and query
        sender: WebSocket sender for sending events back to client
    """
    try:
        # Extract request data
        payload = body.get("payload", {})
        session_data = payload.get("cooking_session", {})
        query = payload.get("query", "")

        if not query:
            await sender.send_error("INVALID_REQUEST", "Query is required")
            return

        logger.info(f"Processing query: {query[:50]}...")

        # Parse cooking session
        try:
            session = CookingSessionBase(**session_data)
        except Exception as e:
            logger.error(f"Session parsing error: {e}")
            await sender.send_error("INVALID_SESSION", f"Invalid session data: {str(e)}")
            return

        # Process query with LangGraph agent
        # Note: For now, we get the full response first
        # TODO: Add token-level streaming in future iteration
        result = await cooking_agent.process_query(session, query)

        full_response = result["response"]
        updated_session = result["updated_session"]

        # Stream response as single token for now
        # TODO: Implement char-by-char or word-by-word streaming
        await sender.send_token(full_response)

        # Generate TTS audio with Polly (if enabled)
        voice_settings = session.user_preferences.voice_settings
        if voice_settings and voice_settings.tts_provider == "polly":
            logger.info("Generating Polly TTS audio")
            polly = PollyService()
            chunk_index = 0

            try:
                async for audio_chunk in polly.stream_audio(full_response, voice_settings):
                    await sender.send_audio(audio_chunk, chunk_index)
                    chunk_index += 1
                    logger.debug(f"Sent audio chunk {chunk_index}")

                logger.info(f"Sent {chunk_index} audio chunks")

            except Exception as e:
                logger.error(f"TTS error (non-fatal): {e}")
                # Continue without audio - client will fall back to device TTS

        # Extract commands from updated session
        # Commands are added during agent processing (timer operations)
        # Use mode='json' to serialize UUIDs and datetimes as strings
        commands = [cmd.model_dump(mode='json') for cmd in updated_session.commands]

        # Send completion event
        await sender.send_done(
            response=full_response,
            session=updated_session.model_dump(mode='json'),
            commands=commands
        )

        logger.info("Query processed successfully")

    except ConnectionAbortedError:
        logger.warning("Client disconnected during query processing")

    except Exception as e:
        logger.error(f"Query error: {e}", exc_info=True)
        try:
            await sender.send_error("QUERY_ERROR", str(e))
        except:
            logger.error("Failed to send error to client")
