"""
AWS Polly TTS Service for streaming audio generation

Provides text-to-speech synthesis using AWS Polly neural voices.
"""

import boto3
import asyncio
import logging
import re
from typing import AsyncIterator
from shared.schemas import VoiceSettings

logger = logging.getLogger(__name__)


class PollyService:
    """
    AWS Polly TTS service for streaming audio generation.

    Features:
    - Neural voice support for higher quality
    - Sentence-level streaming to reduce latency
    - MP3 output format optimized for web delivery
    """

    # Map of friendly voice names to Polly voice IDs
    VOICE_MAPPING = {
        "Joanna": "Joanna",          # US English, Female, Neural
        "Matthew": "Matthew",        # US English, Male, Neural
        "Ruth": "Ruth",              # US English, Female, Neural
        "Stephen": "Stephen",        # US English, Male, Neural
        "Aria": "Aria",              # New Zealand English, Female, Neural
        "Amy": "Amy",                # British English, Female, Neural
        "Brian": "Brian",            # British English, Male, Neural
        "Emma": "Emma",              # British English, Female, Neural
        "Olivia": "Olivia",          # Australian English, Female, Neural
        "Salli": "Salli",            # US English, Female, Neural
    }

    def __init__(self):
        """Initialize Polly client."""
        self.polly = boto3.client("polly")

    async def stream_audio(
        self,
        text: str,
        voice_settings: VoiceSettings
    ) -> AsyncIterator[bytes]:
        """
        Stream audio in chunks from Polly.

        Args:
            text: Text to synthesize
            voice_settings: Voice configuration

        Yields:
            MP3 audio chunks (bytes)
        """
        voice_id = voice_settings.voice_id or "Joanna"

        # Map friendly name to Polly voice ID
        if voice_id in self.VOICE_MAPPING:
            voice_id = self.VOICE_MAPPING[voice_id]

        logger.info(f"Generating TTS with voice: {voice_id}")

        # Split text into sentences for streaming
        # (Polly has 3000 char limit per request)
        sentences = self._split_into_sentences(text)

        for i, sentence in enumerate(sentences):
            if not sentence.strip():
                continue

            logger.debug(f"Synthesizing sentence {i+1}/{len(sentences)}: {sentence[:50]}...")

            # Run sync Polly call in thread pool
            audio_data = await asyncio.get_event_loop().run_in_executor(
                None,
                self._synthesize_speech,
                sentence,
                voice_id
            )

            # Yield audio data
            if audio_data:
                yield audio_data
            else:
                logger.warning(f"Empty audio data for sentence {i+1}")

    def _synthesize_speech(self, text: str, voice_id: str) -> bytes:
        """
        Synchronous Polly synthesis.

        Args:
            text: Text to synthesize
            voice_id: Polly voice ID

        Returns:
            MP3 audio bytes
        """
        try:
            response = self.polly.synthesize_speech(
                Text=text,
                OutputFormat="mp3",
                VoiceId=voice_id,
                Engine="neural",  # Use neural voices for better quality
                SampleRate="24000"  # 24kHz for good quality, lower bandwidth than 44.1kHz
            )

            # Read entire audio stream
            audio_data = response["AudioStream"].read()
            logger.debug(f"Generated {len(audio_data)} bytes of audio")
            return audio_data

        except Exception as e:
            logger.error(f"Polly synthesis error: {e}", exc_info=True)
            return b""

    def _split_into_sentences(self, text: str, max_length: int = 2000) -> list[str]:
        """
        Split text into sentences for streaming.

        Args:
            text: Full text to split
            max_length: Maximum length per chunk (Polly limit is 3000)

        Returns:
            List of sentence strings
        """
        # Split on sentence boundaries (., !, ?)
        # Keep punctuation with sentences
        sentences = re.split(r'(?<=[.!?])\s+', text)

        # Combine very short sentences and split long ones
        result = []
        current = ""

        for sentence in sentences:
            # If adding this sentence would exceed max length, yield current
            if current and len(current) + len(sentence) > max_length:
                result.append(current.strip())
                current = sentence
            else:
                current += " " + sentence if current else sentence

        # Add remaining text
        if current.strip():
            result.append(current.strip())

        logger.debug(f"Split text into {len(result)} sentences")
        return result
