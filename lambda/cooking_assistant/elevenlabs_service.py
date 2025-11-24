"""
ElevenLabs Text-to-Speech Service using the official ElevenLabs Python SDK
"""

import logging
import asyncio
import os
from typing import Optional, Dict, Any, List
from elevenlabs.client import ElevenLabs
from elevenlabs import Voice, VoiceSettings as ElevenLabsVoiceSettings

import sys
sys.path.append(os.path.join(os.path.dirname(__file__), '..'))

from shared.schemas import ElevenLabsSettings

logger = logging.getLogger(__name__)


class ElevenLabsError(Exception):
    """Base exception for ElevenLabs API errors"""
    pass


class ElevenLabsService:
    """Service for interacting with ElevenLabs API using the official SDK"""

    # Voice name to voice ID mapping for popular ElevenLabs voices
    VOICE_MAPPING = {
        "Rachel - calm": "21m00Tcm4TlvDq8ikWAM",
        "Josh - intelligent": "TxGEqnHWrfWFTfGW9XjX",
        "Arnold - crisp": "VR6AewLTigWG4xSOukaG",
        "Adam - storytelling": "pNInz6obpgDQGcFmaJgB",
        "Antoni - well-rounded": "ErXwobaYiN019PkySvjV",
        "Domi - nurturing": "AZnzlk1XvdvUeBnXmlld",
        "Elli - emotional": "MF3mGyEYCl7XYWbV9V6O",
        "Freya - conversational": "jsCqWAovK2LkecY7zXl4",
        "Grace - american-southern": "oWAxZDx7w5VEj9dCyTzz",
        "Sam - storytelling": "yoZ06aMxZJJ28mfd3POQ",
        "Glinda - warm": "z9fAnlkpzviPz146aGWa",
        "Jessica - expressive": "cgSgspJ2msm6clMCkdW9",
        "Nicole - whispering": "piTKgcLEGmPE4e6mEKli",
        "Sarah - conversational": "EXAVITQu4vr4xnSDxMaL"
    }

    def __init__(self):
        self.system_api_key = os.environ.get('ELEVENLABS_API_KEY')

    def _get_client(self, api_key: Optional[str] = None) -> ElevenLabs:
        """Get ElevenLabs client with appropriate API key"""
        key = api_key or self.system_api_key
        if not key:
            raise ElevenLabsError("ElevenLabs API key not configured")

        return ElevenLabs(api_key=key)

    def _get_voice_id(self, voice_name: str) -> str:
        """Get voice ID from voice name"""
        voice_id = self.VOICE_MAPPING.get(voice_name)
        if not voice_id:
            # Fallback to Rachel if voice name not found
            logger.warning(f"Voice name '{voice_name}' not found in mapping, using default 'Rachel - calm'")
            voice_id = self.VOICE_MAPPING["Rachel - calm"]
        return voice_id

    async def text_to_speech(
        self,
        text: str,
        voice_settings: ElevenLabsSettings
    ) -> bytes:
        """
        Convert text to speech using ElevenLabs API

        Args:
            text: Text to convert to speech
            voice_settings: ElevenLabs voice configuration (only enabled and voice_name)

        Returns:
            Audio data as bytes (MP3 format)

        Raises:
            ElevenLabsError: If API request fails
        """
        if not voice_settings.enabled:
            raise ElevenLabsError("ElevenLabs is not enabled in user preferences")

        if not self.system_api_key:
            raise ElevenLabsError("ElevenLabs API key not configured")

        try:
            voice_id = self._get_voice_id(voice_settings.voice_name)
            logger.info(f"ELEVENLABS: Converting text to speech (voice: {voice_settings.voice_name} -> {voice_id}, model: eleven_flash_v2_5)")

            # Run the synchronous ElevenLabs API call in a thread pool
            def _convert_text():
                client = self._get_client()

                # Generate audio using ElevenLabs API with eleven_flash_v2_5 model
                audio_generator = client.text_to_speech.convert(
                    text=text,
                    voice_id=voice_id,
                    model_id="eleven_flash_v2_5",
                    output_format="mp3_44100_128"
                )

                # Collect all audio chunks
                audio_data = b"".join(audio_generator)
                return audio_data

            # Run in thread pool to avoid blocking the event loop
            audio_data = await asyncio.get_event_loop().run_in_executor(None, _convert_text)

            logger.info(f"ELEVENLABS: Successfully generated {len(audio_data)} bytes of audio")
            return audio_data

        except Exception as e:
            logger.error(f"ELEVENLABS: Error during text-to-speech conversion: {str(e)}")
            raise ElevenLabsError(f"ElevenLabs text-to-speech error: {str(e)}")

    async def get_voices(self) -> Dict[str, Any]:
        """
        Get available voice names from our predefined mapping

        Returns:
            Dictionary containing voice names and descriptions
        """
        try:
            logger.info("ELEVENLABS: Returning predefined voice mapping")

            # Return our predefined voice mapping with display names
            voices_data = {
                "voices": [
                    {"voice_name": voice_name, "voice_id": voice_id}
                    for voice_name, voice_id in self.VOICE_MAPPING.items()
                ]
            }

            logger.info(f"ELEVENLABS: Returned {len(voices_data['voices'])} predefined voices")
            return voices_data

        except Exception as e:
            logger.error(f"ELEVENLABS: Error getting voices: {str(e)}")
            raise ElevenLabsError(f"ElevenLabs voices error: {str(e)}")

    async def test_voice(
        self,
        voice_name: str,
        text: str = "Hello! This is a test of this voice."
    ) -> bytes:
        """
        Test a voice with a short phrase for voice selection

        Args:
            voice_name: ElevenLabs voice name to test (e.g., "Rachel - calm")
            text: Test text to speak (default provided)

        Returns:
            Audio data as bytes (MP3 format)

        Raises:
            ElevenLabsError: If API request fails
        """
        if not self.system_api_key:
            raise ElevenLabsError("ElevenLabs API key not configured")

        try:
            voice_id = self._get_voice_id(voice_name)
            logger.info(f"ELEVENLABS: Testing voice {voice_name} -> {voice_id} with text: '{text[:50]}...'")

            def _test_voice():
                client = self._get_client()

                # Use default voice settings for testing
                voice_config = ElevenLabsVoiceSettings(
                    stability=0.5,
                    similarity_boost=0.8,
                    style=0.0,
                    use_speaker_boost=True
                )

                # Convert text to speech using eleven_flash_v2_5 model
                audio_generator = client.text_to_speech.convert(
                    text=text,
                    voice_id=voice_id,
                    model_id="eleven_flash_v2_5",
                    voice_settings=voice_config,
                    output_format="mp3_44100_128"
                )

                # Collect all audio chunks
                audio_data = b"".join(audio_generator)
                return audio_data

            # Run in thread pool to avoid blocking the event loop
            audio_data = await asyncio.get_event_loop().run_in_executor(None, _test_voice)

            logger.info(f"ELEVENLABS: Successfully generated test audio ({len(audio_data)} bytes)")
            return audio_data

        except Exception as e:
            logger.error(f"ELEVENLABS: Error testing voice {voice_name}: {str(e)}")
            raise ElevenLabsError(f"ElevenLabs voice test error: {str(e)}")


# Global service instance
elevenlabs_service = ElevenLabsService()
