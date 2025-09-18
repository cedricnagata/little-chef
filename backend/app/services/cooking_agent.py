"""
LangGraph-based cooking agent with tool-calling architecture for intelligent recipe assistance.
"""

import uuid
import logging
from datetime import datetime
from typing import Dict, Any, Optional, TypedDict, List, Literal
from langgraph.graph import StateGraph, START, END
from langgraph.prebuilt import ToolNode
from langchain_core.messages import HumanMessage, AIMessage, ToolMessage, BaseMessage
from langchain_core.tools import BaseTool
from langchain_openai import ChatOpenAI

from app.schemas import CookingSessionBase, Message, Command
from app.config import settings
from app.services.agent_tools import create_cooking_tools, process_tool_result
from app.prompts import (
    COOKING_ASSISTANT_SYSTEM,
    PLANNING_PROMPT,
    EXECUTOR_SYSTEM,
    RESPONSE_SYNTHESIS
)

# Set up logger
logger = logging.getLogger(__name__)


class AgentState(TypedDict):
    """State maintained throughout the agent workflow"""
    cooking_session: CookingSessionBase
    current_query: str
    messages: List[BaseMessage]  # Conversation messages including tool calls
    plan: Optional[str]  # Agent's plan for handling the query
    tools_executed: List[str]  # Track which tools have been executed
    final_response: str
    error: Optional[str]
    is_ready_to_respond: bool  # Signal when agent is ready to generate final response


class CookingAgent:
    """LangGraph-based cooking agent with planning-execution-response workflow
    
    Workflow: PLANNER → EXECUTOR ⟷ TOOLS → RESPONDER
    - PLANNER: Analyzes queries and creates execution plans
    - EXECUTOR: Implements plans using tools and responses  
    - TOOLS: Executes individual tools (timers, etc.)
    - RESPONDER: Generates comprehensive final responses
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
            openai_api_key=settings.openai_api_key
        )
        return llm.bind_tools(self.tools) if include_tools else llm
    
    def _create_workflow(self) -> StateGraph:
        """Create the LangGraph workflow with planning-execution-response structure"""
        workflow = StateGraph(AgentState)
        
        # Add nodes
        workflow.add_node("planner", self._planner_node)
        workflow.add_node("executor", self._executor_node)
        workflow.add_node("tools", self._tool_node)
        workflow.add_node("responder", self._responder_node)
        
        # Define workflow
        workflow.add_edge(START, "planner")
        workflow.add_edge("planner", "executor")
        workflow.add_conditional_edges(
            "executor",
            self._should_continue_execution,
            {
                "use_tools": "tools",
                "respond": "responder"
            }
        )
        workflow.add_edge("tools", "executor")
        workflow.add_edge("responder", END)
        
        return workflow
    
    def _should_continue_execution(self, state: AgentState) -> Literal["use_tools", "respond"]:
        """Determine if executor should use tools or move to response generation"""
        if state.get("is_ready_to_respond", False):
            logger.info("Executor routing: ready to respond")
            return "respond"
        
        last_message = state["messages"][-1]
        if isinstance(last_message, AIMessage) and last_message.tool_calls:
            logger.info(f"Executor routing: using tools ({len(last_message.tool_calls)} tool calls)")
            return "use_tools"
        else:
            logger.info("Executor routing: moving to response generation")
            return "respond"
    
    async def _planner_node(self, state: AgentState) -> AgentState:
        """Planning node that analyzes the query and creates an execution plan"""
        cooking_session = state["cooking_session"]
        logger.info(f"Planner: analyzing query '{state['current_query'][:50]}...'")
        
        try:
            # Create planning prompt using centralized prompts
            system_context = self._build_system_context(cooking_session)
            prompt_content = PLANNING_PROMPT.format(
                context=system_context,
                query=state['current_query']
            )
            
            # Get plan from LLM
            user_model = cooking_session.user_preferences.llm_model
            llm = self._create_llm(user_model, include_tools=False)
            
            response = await llm.ainvoke([HumanMessage(content=prompt_content)])
            
            # Initialize state for execution
            state["plan"] = response.content
            state["tools_executed"] = []
            state["is_ready_to_respond"] = False
            
            logger.info(f"Planner: created execution plan ({len(response.content)} chars)")
            
        except Exception as e:
            logger.error(f"Planner error: {str(e)}")
            state["error"] = f"Planning error: {str(e)}"
            state["plan"] = "Handle the user query directly"
        
        return state
    
    async def _executor_node(self, state: AgentState) -> AgentState:
        """Executor node that implements the plan using tools and direct responses"""
        logger.info("Executor: implementing plan")
        
        try:
            cooking_session = state["cooking_session"]
            messages = state.get("messages", [])
            
            if not messages:
                # Initialize execution with plan context
                system_context = self._build_system_context(cooking_session)
                assistant_prompt = COOKING_ASSISTANT_SYSTEM.format(context=system_context)
                
                system_message = EXECUTOR_SYSTEM.format(
                    assistant_prompt=assistant_prompt,
                    plan=state.get('plan', 'Handle the user query')
                )
                
                messages = [
                    HumanMessage(content=system_message),
                    HumanMessage(content=state["current_query"])
                ]
                logger.info("Executor: initialized with plan context")
            
            # Execute with tools
            user_model = cooking_session.user_preferences.llm_model
            llm = self._create_llm(user_model, include_tools=True)
            
            response = await llm.ainvoke(messages)
            messages.append(response)
            
            # Determine next action based on response
            if hasattr(response, 'tool_calls') and response.tool_calls:
                # Track tool usage
                for tc in response.tool_calls:
                    tool_name = tc.get('name', 'unknown')
                    if tool_name not in state["tools_executed"]:
                        state["tools_executed"].append(tool_name)
                logger.info(f"Executor: {len(response.tool_calls)} tool calls queued")
            else:
                # No tools needed, ready to respond
                state["is_ready_to_respond"] = True
                logger.info("Executor: ready to respond")
            
            state["messages"] = messages
            
        except Exception as e:
            logger.error(f"Executor error: {str(e)}")
            state["error"] = f"Execution error: {str(e)}"
            state["is_ready_to_respond"] = True
        
        return state
    
    async def _responder_node(self, state: AgentState) -> AgentState:
        """Response node that generates the final comprehensive response"""
        logger.info("Responder: generating final response")
        
        try:
            # Create response synthesis prompt
            tools_used = ', '.join(state.get("tools_executed", [])) or 'None'
            prompt_content = RESPONSE_SYNTHESIS.format(
                query=state['current_query'],
                tools_used=tools_used
            )
            
            # Generate final response
            messages = state.get("messages", []) + [HumanMessage(content=prompt_content)]
            
            cooking_session = state["cooking_session"]
            user_model = cooking_session.user_preferences.llm_model
            llm = self._create_llm(user_model, include_tools=False)
            
            final_response = await llm.ainvoke(messages)
            state["final_response"] = final_response.content
            
            logger.info(f"Responder: generated final response ({len(final_response.content)} chars)")
            
        except Exception as e:
            logger.error(f"Responder error: {str(e)}")
            state["error"] = f"Response generation error: {str(e)}"
            state["final_response"] = "I apologize, but I encountered an error while generating my response."
        
        return state
    
    async def _tool_node(self, state: AgentState) -> AgentState:
        """Execute tools and update state"""
        try:
            last_message = state["messages"][-1]
            if isinstance(last_message, AIMessage) and last_message.tool_calls:
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
                    
                    # Add tool message to conversation
                    tool_messages.append(
                        ToolMessage(
                            content=str(tool_result),
                            tool_call_id=tool_id
                        )
                    )
                
                state["messages"].extend(tool_messages)
                logger.info(f"Tool execution complete: {len(last_message.tool_calls)} tools executed")
            else:
                logger.warning("Tool node called but no tool calls found")
                
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
        
        # Timer information
        self._add_timer_context(context_parts, cooking_session)
        
        # Recent conversation
        self._add_conversation_context(context_parts, cooking_session)
        
        return "\n".join(context_parts)
    
    def _add_timer_context(self, context_parts: List[str], cooking_session: CookingSessionBase) -> None:
        """Add timer information to context"""
        # Available timers from commands
        timers = [
            {
                "id": cmd.target_id,
                "label": cmd.label,
                "duration": cmd.parameters["duration_seconds"] // 60
            }
            for cmd in cooking_session.commands
            if (cmd.command_type == "timer" and cmd.action == "add" and 
                cmd.target_id and "duration_seconds" in cmd.parameters)
        ]
        
        if timers:
            context_parts.append("\nAvailable timers:")
            for timer in timers:
                context_parts.append(f"- {timer['label']} (ID: {timer['id']}) - {timer['duration']}m")
        
        # Current timer status
        if cooking_session.timer_status:
            context_parts.append("\nCurrent timer status:")
            for timer in cooking_session.timer_status:
                remaining_min = timer.remaining_seconds // 60
                context_parts.append(f"- {timer.label} - {timer.status}, {remaining_min}m remaining")
    
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
    
    async def process_query(self, cooking_session: CookingSessionBase, query: str) -> Dict[str, Any]:
        """Process a cooking query and return the response with updated session"""
        
        query_preview = query.strip()[:50] + "..." if len(query.strip()) > 50 else query.strip()
        logger.info(f"Workflow start: processing query '{query_preview}' for recipe '{cooking_session.recipe.title}'")
        
        # Initialize agent state
        initial_state: AgentState = {
            "cooking_session": cooking_session,
            "current_query": query.strip(),
            "messages": [],
            "plan": None,
            "tools_executed": [],
            "final_response": "",
            "error": None,
            "is_ready_to_respond": False
        }
        
        try:
            # Run the agent workflow
            result = await self.compiled_agent.ainvoke(initial_state)
            
            # Update conversation history
            updated_session = result["cooking_session"]
            
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