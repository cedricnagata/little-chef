"""
Agent tools for cooking knowledge and assistance.
"""

import logging
from typing import List
from langchain_openai import ChatOpenAI
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.tools import BaseTool, tool
from pydantic import BaseModel, Field

from app.config import settings
from app.schemas import RecipeBase
from app.prompts import get_cooking_prompts
import re

# Set up logger
logger = logging.getLogger(__name__)


# Tool input schemas
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


class CookingQuestionInput(BaseModel):
    """Input schema for cooking guidance questions"""
    question: str = Field(description="Cooking question or request for guidance")


class KnowledgeTools:
    """Tools for cooking knowledge and advice"""
    
    def __init__(self):
        self._llm_cache = {}
    
    def _get_llm(self, model_name: str) -> ChatOpenAI:
        """Get or create LLM instance with caching"""
        if model_name not in self._llm_cache:
            self._llm_cache[model_name] = ChatOpenAI(
                model=model_name,
                temperature=0.1,
                verbosity="low",
                openai_api_key=settings.openai_api_key
            )
        
        return self._llm_cache[model_name]
    
    # NOTE: Recipe modification logic removed. Frontend now sends
    # RecipeBase objects with already-scaled ingredients and servings.
    
    # NOTE: Ingredient scaling logic removed. Frontend now sends
    # RecipeBase objects with already-scaled ingredients.
    
    async def get_cooking_knowledge(self, query: str, recipe_context: RecipeBase, conversation_history: list, model: str) -> str:
        """Get cooking knowledge relevant to the query and recipe"""
        logger.info(f"KNOWLEDGE: Processing cooking knowledge request with {model}")
        logger.info(f"KNOWLEDGE: Query: '{query[:100]}...'")
        logger.info(f"KNOWLEDGE: Recipe: {recipe_context.title}")
        
        try:
            llm = self._get_llm(model)
            
            # Build context about the recipe
            context = f"Recipe: {recipe_context.title}\n"
            context += f"Servings: {recipe_context.servings}\n"
            context += f"Cuisine: {recipe_context.cuisine_type or 'General'}\n"
            context += f"Ingredients: {', '.join(recipe_context.ingredients[:5])}\n"
            if len(recipe_context.ingredients) > 5:
                context += f"...and {len(recipe_context.ingredients) - 5} more ingredients\n"
            context += f"Cooking time: {recipe_context.cook_time or 'Not specified'} minutes\n"
            context += f"Difficulty: {recipe_context.difficulty or 'Not specified'}"
            
            # Build conversation history context
            conversation_context = ""
            if conversation_history and len(conversation_history) > 0:
                conversation_context = "\n\nPrevious conversation:\n"
                # Include the last 10 messages to avoid token limits but maintain context
                recent_messages = conversation_history[-10:] if len(conversation_history) > 10 else conversation_history
                for message in recent_messages:
                    role = "User" if message.role == "user" else "Assistant"
                    conversation_context += f"{role}: {message.content}\n"
            
            prompt = ChatPromptTemplate.from_messages([
                ("system", get_cooking_prompts()["knowledge_system"]),
                ("human", get_cooking_prompts()["knowledge_template"].format(
                    context=context + conversation_context,
                    query=query
                ))
            ])
            
            logger.info("KNOWLEDGE: Built context and prompt, calling LLM for cooking guidance...")
            chain = prompt | llm
            response = await chain.ainvoke({})
            
            logger.info(f"KNOWLEDGE: Generated cooking guidance: {response.content[:100]}...")
            return response.content
            
        except Exception as e:
            logger.error(f"KNOWLEDGE: Error getting cooking knowledge: {str(e)}")
            return f"I'd love to help with that cooking question, but I'm having trouble accessing my knowledge right now. Could you try asking again? Error: {str(e)}"


def create_cooking_tools() -> List[BaseTool]:
    """Create and return all cooking-related tools for the agent"""
    
    @tool("add_timer", args_schema=AddTimerInput)
    def add_timer(label: str, duration_minutes: int) -> str:
        """Add a new cooking timer with specified duration and label."""
        import uuid
        timer_id = str(uuid.uuid4())
        logger.info(f"TOOL_add_timer: Creating timer '{label}' for {duration_minutes} minutes (ID: {timer_id})")
        return f"timer_added:{timer_id}:{label}:{duration_minutes * 60}"
    
    @tool("start_timer", args_schema=StartTimerInput)
    def start_timer(timer_id: str) -> str:
        """Start an existing timer."""
        logger.info(f"TOOL_start_timer: Starting timer {timer_id}")
        return f"timer_started:{timer_id}"
    
    @tool("stop_timer", args_schema=StopTimerInput)
    def stop_timer(timer_id: str) -> str:
        """Stop a running timer."""
        logger.info(f"TOOL_stop_timer: Stopping timer {timer_id}")
        return f"timer_stopped:{timer_id}"
    
    @tool("remove_timer", args_schema=RemoveTimerInput)
    def remove_timer(timer_id: str) -> str:
        """Remove/delete a timer completely."""
        logger.info(f"TOOL_remove_timer: Removing timer {timer_id}")
        return f"timer_removed:{timer_id}"
    
    @tool("get_cooking_guidance", args_schema=CookingQuestionInput)
    def get_cooking_guidance(question: str) -> str:
        """Get cooking advice, techniques, or recipe guidance."""
        logger.info(f"TOOL_get_cooking_guidance: Processing question: '{question[:100]}...'")
        # This will be handled by the tool executor calling the actual cooking knowledge
        return f"cooking_guidance_request:{question}"
    
    return [add_timer, start_timer, stop_timer, remove_timer, get_cooking_guidance]
