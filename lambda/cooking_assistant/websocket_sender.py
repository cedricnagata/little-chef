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

    async def send_audio(self, data: bytes, chunk_index: int) -> None:
        """
        Send an audio chunk event.

        Args:
            data: Raw audio bytes (MP3 format)
            chunk_index: Sequential index for chunk ordering
        """
        await self.send({
            "type": "audio",
            "data": base64.b64encode(data).decode("utf-8"),
            "format": "mp3",
            "chunk_index": chunk_index
        })

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
