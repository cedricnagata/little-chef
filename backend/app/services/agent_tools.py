"""
Cooking agent tools and utilities.

This module provides:
- Timer management tools (add, start, stop, remove)
- Tool result processing utilities
- Input validation schemas for tools
"""

import logging
from typing import List
from langchain_core.tools import BaseTool, tool
from pydantic import BaseModel, Field
from typing import Dict
from app.schemas import Command

# Set up logger
logger = logging.getLogger(__name__)


# ===== Tool Input Schemas =====
class AddTimerInput(BaseModel):
    """Input schema for adding a timer"""
    label: str = Field(description="Label for the timer (e.g., 'Boil pasta', 'Rest dough')")
    duration_minutes: int = Field(description="Duration in minutes for the timer", ge=1)


class StartTimerInput(BaseModel):
    """Input schema for starting a timer"""
    timer_id: str = Field(description="ID of the timer to start")


class StopTimerInput(BaseModel):
    """Input schema for stopping a timer"""
    timer_id: str = Field(description="ID of the timer to stop")


class RemoveTimerInput(BaseModel):
    """Input schema for removing a timer"""
    timer_id: str = Field(description="ID of the timer to remove")


# ===== Tool Creation =====

def create_cooking_tools() -> List[BaseTool]:
    """Create and return all cooking-related tools for the agent"""
    
    @tool("add_timer", args_schema=AddTimerInput)
    def add_timer(label: str, duration_minutes: int) -> str:
        """Add a new cooking timer with specified duration and label."""
        import uuid
        timer_id = str(uuid.uuid4())
        logger.info(f"Timer add: '{label}' for {duration_minutes} minutes (ID: {timer_id})")
        return f"timer_added:{timer_id}:{label}:{duration_minutes * 60}"
    
    @tool("start_timer", args_schema=StartTimerInput)
    def start_timer(timer_id: str) -> str:
        """Start an existing timer."""
        logger.info(f"Timer start: {timer_id}")
        return f"timer_started:{timer_id}"
    
    @tool("stop_timer", args_schema=StopTimerInput)
    def stop_timer(timer_id: str) -> str:
        """Stop a running timer."""
        logger.info(f"Timer stop: {timer_id}")
        return f"timer_stopped:{timer_id}"
    
    @tool("remove_timer", args_schema=RemoveTimerInput)
    def remove_timer(timer_id: str) -> str:
        """Remove/delete a timer completely."""
        logger.info(f"Timer remove: {timer_id}")
        return f"timer_removed:{timer_id}"
    
    return [add_timer, start_timer, stop_timer, remove_timer]


# ===== Tool Result Processing =====

def process_tool_result(cooking_session, tool_call: Dict, tool_result: str) -> None:
    """Process tool results and update cooking session state with appropriate commands
    
    Args:
        cooking_session: The cooking session to update
        tool_call: The tool call information from LLM
        tool_result: The result string returned by the tool
    """
    tool_name = tool_call["name"]
    
    if tool_name == "add_timer" and tool_result.startswith("timer_added:"):
        # Parse: "timer_added:timer_id:label:duration_seconds"
        parts = tool_result.split(":", 3)
        if len(parts) == 4:
            timer_id = parts[1]
            label = parts[2]
            duration_seconds = int(parts[3])
            
            # Create universal command for timer add
            command = Command(
                command_type="timer",
                action="add",
                target_id=timer_id,
                label=label,
                parameters={"duration_seconds": duration_seconds}
            )
            cooking_session.commands.append(command)
    
    elif tool_name == "start_timer" and tool_result.startswith("timer_started:"):
        timer_id = tool_result.split(":", 1)[1]
        command = Command(
            command_type="timer",
            action="start",
            target_id=timer_id,
            label="Start timer"
        )
        cooking_session.commands.append(command)
    
    elif tool_name == "stop_timer" and tool_result.startswith("timer_stopped:"):
        timer_id = tool_result.split(":", 1)[1]
        command = Command(
            command_type="timer",
            action="stop",
            target_id=timer_id,
            label="Stop timer"
        )
        cooking_session.commands.append(command)
    
    elif tool_name == "remove_timer" and tool_result.startswith("timer_removed:"):
        timer_id = tool_result.split(":", 1)[1]
        command = Command(
            command_type="timer",
            action="remove",
            target_id=timer_id,
            label="Remove timer"
        )
        cooking_session.commands.append(command)
