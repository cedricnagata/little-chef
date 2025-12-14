"""
WebSocket Lambda Handler for LittleChef Cooking Assistant

Handles WebSocket connections, disconnections, and message routing.
"""

import json
import asyncio
import logging
from typing import Dict, Any

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Entry point for all WebSocket events.

    Routes WebSocket lifecycle events ($connect, $disconnect, $default)
    and delegates message processing to async handler.
    """
    try:
        # Run async handler in event loop
        return asyncio.get_event_loop().run_until_complete(
            async_handler(event, context)
        )
    except Exception as e:
        logger.error(f"Handler error: {e}", exc_info=True)
        return {"statusCode": 500}


async def async_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Async WebSocket event handler.

    Handles:
    - $connect: Client connection established
    - $disconnect: Client disconnected
    - $default: Message received from client
    """
    route_key = event.get("requestContext", {}).get("routeKey")
    connection_id = event["requestContext"]["connectionId"]

    logger.info(f"Route: {route_key}, Connection: {connection_id}")

    # Handle connection lifecycle
    if route_key == "$connect":
        logger.info(f"Client connected: {connection_id}")
        return {"statusCode": 200}

    if route_key == "$disconnect":
        logger.info(f"Client disconnected: {connection_id}")
        return {"statusCode": 200}

    # Handle messages ($default route)
    try:
        # Parse message body
        body = event.get("body", "{}")
        if isinstance(body, str):
            body = json.loads(body)

        action = body.get("action")
        request_id = body.get("request_id", "unknown")

        logger.info(f"Action: {action}, Request ID: {request_id}")

        # Get API Gateway connection info
        domain = event["requestContext"]["domainName"]
        stage = event["requestContext"]["stage"]
        endpoint = f"https://{domain}/{stage}"

        # Import handlers here to avoid circular imports
        from websocket_sender import WebSocketSender
        from query_handler import handle_query

        # Create sender for this connection
        sender = WebSocketSender(connection_id, endpoint, request_id)

        # Route to appropriate handler
        if action == "query":
            await handle_query(body, sender)
        else:
            await sender.send_error("UNKNOWN_ACTION", f"Unknown action: {action}")

        return {"statusCode": 200}

    except json.JSONDecodeError as e:
        logger.error(f"JSON decode error: {e}")
        return {"statusCode": 400, "body": "Invalid JSON"}

    except Exception as e:
        logger.error(f"Message processing error: {e}", exc_info=True)

        # Try to send error to client
        try:
            from websocket_sender import WebSocketSender
            domain = event["requestContext"]["domainName"]
            stage = event["requestContext"]["stage"]
            endpoint = f"https://{domain}/{stage}"
            sender = WebSocketSender(connection_id, endpoint, request_id)
            await sender.send_error("INTERNAL_ERROR", str(e))
        except:
            pass

        return {"statusCode": 500}
