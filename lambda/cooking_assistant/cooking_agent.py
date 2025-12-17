"""
LangGraph-based cooking agent with tool-calling architecture for intelligent recipe assistance.
"""

import uuid
import logging
import os
from datetime import datetime
from typing import Dict, Any, Optional, TypedDict, List, Literal
from langgraph.graph import StateGraph, START, END
from langgraph.prebuilt import ToolNode
from langchain_core.messages import HumanMessage, AIMessage, ToolMessage, BaseMessage, SystemMessage
from langchain_core.tools import BaseTool
from langchain_openai import ChatOpenAI

import sys
sys.path.append(os.path.join(os.path.dirname(__file__), '..'))

from shared.schemas import CookingSessionBase, Message, Command
from agent_tools import create_cooking_tools, process_tool_result
from prompts import COOKING_ASSISTANT_SYSTEM

# Set up logger
logger = logging.getLogger(__name__)


class AgentState(TypedDict):
    """Simple state for agent workflow"""
    cooking_session: CookingSessionBase
    current_query: str
    messages: List[BaseMessage]
    final_response: str
    error: Optional[str]


class CookingAgent:
    """Simple LangGraph-based cooking agent

    Workflow: AGENT → [TOOLS] → END
    - AGENT: Handles queries, calls tools, provides responses
    - TOOLS: Executes timer tools when needed
    """

    def __init__(self):
        self.tools = self._create_tools()
        self.tool_node = ToolNode(self.tools)
        self.workflow = self._create_workflow()
        self._compiled_agent = None

    @property
    def compiled_agent(self):
        """Lazy initialization of compiled agent"""
        if self._compiled_agent is None:
            self._compiled_agent = self.workflow.compile()
        return self._compiled_agent

    def _create_tools(self) -> List[BaseTool]:
        """Create tools for the agent"""
        return create_cooking_tools()

    def _create_llm(self, model: str, include_tools: bool = False) -> ChatOpenAI:
        """Create LLM instance with optional tool binding"""
        llm = ChatOpenAI(
            model=model,
            temperature=0.1,
            openai_api_key=os.environ.get('OPENAI_API_KEY')
        )
        return llm.bind_tools(self.tools) if include_tools else llm

    def _create_workflow(self) -> StateGraph:
        """Create agent workflow: AGENT ⟷ TOOLS with proper synthesis"""
        workflow = StateGraph(AgentState)

        # Add nodes
        workflow.add_node("agent", self._agent_node)
        workflow.add_node("tools", self._tool_node)

        # Define workflow
        workflow.add_edge(START, "agent")
        workflow.add_conditional_edges(
            "agent",
            self._should_continue,
            {
                "use_tools": "tools",
                "end": END
            }
        )
        workflow.add_edge("tools", "agent")  # Return to agent after tools

        return workflow

    def _should_continue(self, state: AgentState) -> Literal["use_tools", "end"]:
        """Determine if agent should use tools or end workflow"""
        # Safety check for empty messages list
        if not state.get("messages"):
            logger.warning("Empty messages list in _should_continue")
            return "end"

        last_message = state["messages"][-1]
        if isinstance(last_message, AIMessage) and last_message.tool_calls:
            return "use_tools"
        else:
            return "end"

    async def _agent_node(self, state: AgentState) -> AgentState:
        """Main agent node that handles queries and calls tools"""
        try:
            cooking_session = state["cooking_session"]
            messages = state.get("messages", [])

            # Initialize conversation with system context and user query
            if not messages:
                system_context = self._build_system_context(cooking_session)
                system_message = COOKING_ASSISTANT_SYSTEM.format(context=system_context)
                messages = [
                    HumanMessage(content=system_message),
                    HumanMessage(content=state["current_query"])
                ]

            # Get response with tools available
            user_model = cooking_session.user_preferences.llm_model
            llm = self._create_llm(user_model, include_tools=True)

            response = await llm.ainvoke(messages)
            messages.append(response)

            # Set final response if no tools called
            if not (hasattr(response, 'tool_calls') and response.tool_calls):
                state["final_response"] = response.content

            state["messages"] = messages

        except Exception as e:
            logger.error(f"Agent error: {str(e)}")
            state["error"] = f"Agent error: {str(e)}"
            state["final_response"] = "I apologize, but I encountered an error while processing your request."

        return state

    async def _tool_node(self, state: AgentState) -> AgentState:
        """Execute tools and update state"""
        try:
            # Safety check for empty messages list
            if not state.get("messages"):
                logger.error("Empty messages list in _tool_node")
                state["error"] = "Internal error: No messages to process"
                return state

            last_message = state["messages"][-1]

            tool_messages = []

            for i, tool_call in enumerate(last_message.tool_calls):
                tool_name = tool_call["name"]
                tool_id = tool_call["id"]
                tool_args = tool_call.get('args', {})

                logger.info(f"Tool execution {i+1}: {tool_name} with args {tool_args}")

                # Execute tool and get result
                tool_func = None
                for tool in self.tools:
                    if tool.name == tool_name:
                        tool_func = tool
                        break

                if tool_func:
                    tool_result = await tool_func.ainvoke(tool_call["args"])
                else:
                    logger.error(f"Tool not found: {tool_name}")
                    tool_result = f"Error: Tool {tool_name} not found"

                # Log result (truncated for readability)
                result_preview = str(tool_result)[:100] + "..." if len(str(tool_result)) > 100 else str(tool_result)
                logger.info(f"Tool result {i+1}: {result_preview}")

                # Process special tool results (timer commands)
                process_tool_result(state["cooking_session"], tool_call, tool_result)

                # Add tool result to conversation
                tool_messages.append(
                    ToolMessage(
                        content=str(tool_result),
                        tool_call_id=tool_id
                    )
                )

            # Add all tool results to conversation
            state["messages"].extend(tool_messages)
        except Exception as e:
            logger.error(f"Tool execution error: {str(e)}")
            state["error"] = f"Tool execution error: {str(e)}"

        return state


    # ===== Utility Methods =====

    def _build_system_context(self, cooking_session: CookingSessionBase) -> str:
        """Build comprehensive system context from cooking session"""
        recipe = cooking_session.recipe
        context_parts = []

        # Recipe header
        header = f"Recipe: {recipe.title} (Servings: {recipe.servings})"
        if recipe.prep_time or recipe.cook_time:
            times = []
            if recipe.prep_time:
                times.append(f"Prep: {recipe.prep_time}m")
            if recipe.cook_time:
                times.append(f"Cook: {recipe.cook_time}m")
            header += f" | {' | '.join(times)}"
        if recipe.difficulty:
            header += f" | Difficulty: {recipe.difficulty}"
        context_parts.append(header)

        # Ingredients
        context_parts.append("\nIngredients:")
        for ingredient in recipe.ingredients:
            context_parts.append(f"- {ingredient}")

        # Instructions
        context_parts.append("\nInstructions:")
        for i, instruction in enumerate(recipe.instructions, 1):
            context_parts.append(f"{i}. {instruction}")

        # Recent conversation
        self._add_conversation_context(context_parts, cooking_session)

        # Timer information
        self._add_timer_context(context_parts, cooking_session)

        return "\n".join(context_parts)

    def _add_timer_context(self, context_parts: List[str], cooking_session: CookingSessionBase) -> None:
        """Add timer information to context"""
        if cooking_session.timer_status:
            context_parts.append("\nCurrent timers:")
            for timer in cooking_session.timer_status:
                duration_min = timer.duration_seconds // 60
                remaining_min = timer.remaining_seconds // 60
                context_parts.append(f"- {timer.label} (ID: {timer.id}) - {duration_min}m total, {remaining_min}m remaining, status: {timer.status}")

    def _add_conversation_context(self, context_parts: List[str], cooking_session: CookingSessionBase) -> None:
        """Add recent conversation to context"""
        if cooking_session.conversation_history:
            recent_messages = cooking_session.conversation_history[-2:]
            if recent_messages:
                context_parts.append("\nRecent conversation:")
                for msg in recent_messages:
                    role = "User" if msg.role == "user" else "Assistant"
                    context_parts.append(f"{role}: {msg.content}")


    # ===== Main Process Method =====

    async def process_query(self, cooking_session: CookingSessionBase, query: str, warmup: bool = False) -> Dict[str, Any]:
        """Process a cooking query and return the response with updated session

        Args:
            cooking_session: Current cooking session with recipe and context
            query: User's query
            warmup: If True, skip adding to conversation history (for Lambda cold start prevention)
        """

        query_preview = query.strip()[:50] + "..." if len(query.strip()) > 50 else query.strip()
        if warmup:
            logger.info(f"Workflow start: processing warmup query (cold start prevention)")
        else:
            logger.info(f"Workflow start: processing query '{query_preview}' for recipe '{cooking_session.recipe.title}'")

        # Initialize agent state
        initial_state: AgentState = {
            "cooking_session": cooking_session,
            "current_query": query.strip(),
            "messages": [],
            "final_response": "",
            "error": None
        }

        try:
            # Run the agent workflow
            result = await self.compiled_agent.ainvoke(initial_state)

            # Update conversation history (skip for warmup queries)
            updated_session = result["cooking_session"]

            if not warmup:
                # Add user message
                user_message = Message(
                    id=uuid.uuid4(),
                    role="user",
                    content=query,
                    timestamp=datetime.now()
                )
                updated_session.conversation_history.append(user_message)

                # Add assistant message
                assistant_message = Message(
                    id=uuid.uuid4(),
                    role="assistant",
                    content=result["final_response"],
                    timestamp=datetime.now()
                )
                updated_session.conversation_history.append(assistant_message)

            final_response_data = {
                "response": result["final_response"],
                "updated_session": updated_session
            }

            response_preview = result["final_response"][:50] + "..." if len(result["final_response"]) > 50 else result["final_response"]
            logger.info(f"Workflow complete: response '{response_preview}' ({len(result['final_response'])} chars)")
            return final_response_data

        except Exception as e:
            logger.error(f"Workflow error: {str(e)}")

            # Add error to conversation history
            error_user_message = Message(
                id=uuid.uuid4(),
                role="user",
                content=query,
                timestamp=datetime.now()
            )
            cooking_session.conversation_history.append(error_user_message)

            error_assistant_message = Message(
                id=uuid.uuid4(),
                role="assistant",
                content=f"I encountered an error while processing your request: {str(e)}. Please try again.",
                timestamp=datetime.now()
            )
            cooking_session.conversation_history.append(error_assistant_message)

            error_response_data = {
                "response": f"I encountered an error while processing your request: {str(e)}. Please try again.",
                "updated_session": cooking_session
            }

            return error_response_data


# Create singleton instance
cooking_agent = CookingAgent()
