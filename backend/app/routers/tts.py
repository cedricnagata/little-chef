"""
Text-to-Speech API endpoints - Standalone TTS service
"""

import logging
from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import BaseModel, Field
from typing import Optional

from ..schemas import ElevenLabsSettings
from ..security import get_current_user_id
from ..services.elevenlabs_service import elevenlabs_service, ElevenLabsError

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/tts", tags=["text-to-speech"])


class TTSRequest(BaseModel):
    """Request schema for text-to-speech conversion"""
    text: str = Field(..., min_length=1, max_length=5000, description="Text to convert to speech")
    voice_settings: ElevenLabsSettings = Field(..., description="ElevenLabs voice configuration")


class VoiceTestRequest(BaseModel):
    """Request schema for testing voices"""
    voice_name: str = Field(..., description="ElevenLabs voice name to test (e.g., 'Rachel - calm')")
    text: str = Field(default="Hello! This is a test of this voice.", max_length=200, description="Test text to speak")


@router.post("/synthesize", response_class=Response)
async def synthesize_speech(
    request: TTSRequest,
    current_user_id: str = Depends(get_current_user_id)
):
    """
    Convert text to speech using ElevenLabs API
    
    Frontend should provide the voice settings from user preferences.
    This keeps the backend stateless and the frontend in control of user state.
    
    Returns MP3 audio data directly
    """
    try:
        # Check if ElevenLabs is enabled
        if not request.voice_settings.enabled:
            raise HTTPException(
                status_code=400,
                detail="ElevenLabs text-to-speech is not enabled"
            )
        
        logger.info(f"TTS: Processing synthesize request for user {current_user_id} (text length: {len(request.text)})")
        
        # Convert text to speech
        audio_data = await elevenlabs_service.text_to_speech(
            text=request.text,
            voice_settings=request.voice_settings
        )
        
        logger.info(f"TTS: Successfully synthesized {len(audio_data)} bytes of audio for user {current_user_id}")
        
        # Return audio data as MP3
        return Response(
            content=audio_data,
            media_type="audio/mpeg",
            headers={
                "Content-Disposition": "attachment; filename=speech.mp3",
                "Content-Length": str(len(audio_data)),
                "Cache-Control": "no-cache"
            }
        )
        
    except ElevenLabsError as e:
        logger.error(f"TTS: ElevenLabs error for user {current_user_id}: {str(e)}")
        raise HTTPException(status_code=400, detail=str(e))
    
    except Exception as e:
        logger.error(f"TTS: Unexpected error for user {current_user_id}: {str(e)}")
        raise HTTPException(status_code=500, detail="Internal server error during text-to-speech conversion")


@router.post("/test-voice", response_class=Response)
async def test_voice(
    request: VoiceTestRequest,
    current_user_id: str = Depends(get_current_user_id)
):
    """
    Test a specific ElevenLabs voice with sample text
    
    This endpoint is designed for use in profile settings to allow users
    to test different voices before saving their preferences.
    Uses system API key and default settings.
    """
    try:
        logger.info(f"TTS: Testing voice {request.voice_name} for user {current_user_id}")
        
        # Test the voice
        audio_data = await elevenlabs_service.test_voice(
            voice_name=request.voice_name,
            text=request.text
        )
        
        logger.info(f"TTS: Successfully generated test audio ({len(audio_data)} bytes) for user {current_user_id}")
        
        # Return audio data as MP3
        return Response(
            content=audio_data,
            media_type="audio/mpeg",
            headers={
                "Content-Disposition": f"attachment; filename=voice_test_{request.voice_name.replace(' ', '_')}.mp3",
                "Content-Length": str(len(audio_data)),
                "Cache-Control": "no-cache"
            }
        )
        
    except ElevenLabsError as e:
        logger.error(f"TTS: Voice test error for user {current_user_id}: {str(e)}")
        raise HTTPException(status_code=400, detail=str(e))
    
    except Exception as e:
        logger.error(f"TTS: Unexpected error testing voice for user {current_user_id}: {str(e)}")
        raise HTTPException(status_code=500, detail="Internal server error during voice test")


@router.get("/voices")
async def get_available_voices(
    current_user_id: str = Depends(get_current_user_id)
):
    """
    Get available voice names from predefined mapping
    
    Returns our curated list of ElevenLabs voices with display names
    """
    try:
        logger.info(f"TTS: Fetching predefined voices for user {current_user_id}")
        
        voices_data = await elevenlabs_service.get_voices()
        
        logger.info(f"TTS: Retrieved voices for user {current_user_id}")
        return voices_data
        
    except ElevenLabsError as e:
        logger.error(f"TTS: Error getting voices for user {current_user_id}: {str(e)}")
        raise HTTPException(status_code=400, detail=str(e))
    
    except Exception as e:
        logger.error(f"TTS: Unexpected error getting voices for user {current_user_id}: {str(e)}")
        raise HTTPException(status_code=500, detail="Internal server error while fetching voices")


