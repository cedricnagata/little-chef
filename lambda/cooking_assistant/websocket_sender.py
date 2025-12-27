"""
WebSocket Sender Utility

Provides helper methods to send messages to WebSocket clients via API Gateway Management API.
"""

import json
import base64
import logging
import boto3
from botocore.exceptions import ClientError
from typing import Dict, Any, List, Optional

logger = logging.getLogger()


class WebSocketSender:
    """
    Utility class for sending messages to WebSocket clients.

    Handles message formatting and API Gateway Management API communication.
    All messages include request_id for client-side filtering.
    """

    def __init__(self, connection_id: str, endpoint: str, request_id: str):
        """
        Initialize WebSocket sender.

        Args:
            connection_id: API Gateway connection ID
            endpoint: API Gateway endpoint URL (https://domain/stage)
            request_id: Unique request identifier for message tracking
        """
        self.connection_id = connection_id
        self.endpoint = endpoint
        self.request_id = request_id
        self.client = boto3.client("apigatewaymanagementapi", endpoint_url=endpoint)

    def _send(self, message: Dict[str, Any]) -> None:
        """
        Send message to WebSocket client (sync).

        Args:
            message: Message dict to send (will be JSON encoded)

        Raises:
            ConnectionAbortedError: If client has disconnected
        """
        # Add request_id to all messages
        message["request_id"] = self.request_id

        try:
            self.client.post_to_connection(
                ConnectionId=self.connection_id,
                Data=json.dumps(message).encode("utf-8")
            )
        except ClientError as e:
            if e.response["Error"]["Code"] == "GoneException":
                logger.warning(f"Connection {self.connection_id} is gone")
                raise ConnectionAbortedError("Client disconnected")
            logger.error(f"Error sending to connection: {e}")
            raise

    async def send(self, message: Dict[str, Any]) -> None:
        """Async wrapper for send."""
        self._send(message)

    async def send_token(self, content: str) -> None:
        """
        Send a text token event.

        Args:
            content: Text token to send
        """
        await self.send({
            "type": "token",
            "content": content
        })

    async def send_tool(
        self,
        status: str,
        tool: str,
        args: Optional[Dict[str, Any]] = None,
        result: Optional[str] = None
    ) -> None:
        """
        Send a tool execution event.

        Args:
            status: "start" or "end"
            tool: Tool name (e.g., "add_timer")
            args: Tool arguments (for start events)
            result: Tool result string (for end events)
        """
        message = {
            "type": "tool",
            "status": status,
            "tool": tool
        }

        if args is not None:
            message["args"] = args

        if result is not None:
            message["result"] = result

        await self.send(message)

    async def send_audio(self, data: bytes, chunk_index: int) -> int:
        """
        Send an audio chunk event.

        AWS API Gateway WebSocket has a 128 KB message limit.
        Base64 encoding adds ~33% overhead, so we split audio at 64 KB
        to ensure the full message (with JSON wrapper) stays under limit.

        Args:
            data: Raw audio bytes (MP3 format)
            chunk_index: Starting index for chunk ordering

        Returns:
            Number of WebSocket messages sent (1 if no split, >1 if split)
        """
        # Max raw audio size before base64 encoding (64 KB to be safe)
        MAX_CHUNK_SIZE = 64 * 1024

        if len(data) <= MAX_CHUNK_SIZE:
            # Small enough to send as single message
            await self.send({
                "type": "audio",
                "data": base64.b64encode(data).decode("utf-8"),
                "format": "mp3",
                "chunk_index": chunk_index
            })
            return 1
        else:
            # Split large audio into smaller sub-chunks with sequential indices
            messages_sent = 0
            for i in range(0, len(data), MAX_CHUNK_SIZE):
                sub_chunk = data[i:i + MAX_CHUNK_SIZE]
                await self.send({
                    "type": "audio",
                    "data": base64.b64encode(sub_chunk).decode("utf-8"),
                    "format": "mp3",
                    "chunk_index": chunk_index + messages_sent
                })
                logger.debug(f"Sent audio sub-chunk {chunk_index + messages_sent} ({len(sub_chunk)} bytes)")
                messages_sent += 1
            return messages_sent

    async def send_done(
        self,
        response: str,
        session: Dict[str, Any],
        commands: List[Dict[str, Any]]
    ) -> None:
        """
        Send completion event.

        Args:
            response: Full text response
            session: Updated session dict
            commands: List of command dicts generated during processing
        """
        await self.send({
            "type": "done",
            "response": response,
            "updated_session": session,
            "commands": commands
        })

    async def send_error(self, code: str, message: str) -> None:
        """
        Send error event.

        Args:
            code: Error code (e.g., "QUERY_ERROR", "AGENT_ERROR")
            message: Human-readable error message
        """
        await self.send({
            "type": "error",
            "code": code,
            "message": message
        })
