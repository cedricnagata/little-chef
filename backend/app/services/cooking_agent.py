"""
LangGraph-based cooking agent with tool-calling architecture for intelligent recipe assistance.
"""

import uuid
import logging
import json
from datetime import datetime
from typing import Dict, Any, Optional, TypedDict, List, Literal
from langgraph.graph import StateGraph, START, END
from langgraph.prebuilt import ToolNode
from langchain_core.messages import HumanMessage, AIMessage, ToolMessage, BaseMessage
from langchain_core.tools import BaseTool
from langchain_openai import ChatOpenAI
# Pydantic import removed - schemas now in agent_tools.py

from app.schemas import CookingSessionBase, Message, Command
from app.config import settings
from app.services.agent_tools import create_cooking_tools, KnowledgeTools

# Set up logger
logger = logging.getLogger(__name__)


class AgentState(TypedDict):
    """State maintained throughout the agent workflow"""
    cooking_session: CookingSessionBase
    current_query: str
    messages: List[BaseMessage]  # Conversation messages including tool calls
    final_response: str
    error: Optional[str]


class CookingAgent:
    """LangGraph-based cooking agent with tool-calling architecture"""
    
    def __init__(self):
        self.tools = self._create_tools()
        self.tool_node = ToolNode(self.tools)
        self.llm = ChatOpenAI(
            model="gpt-4o-mini",
            temperature=0.1,
            openai_api_key=settings.openai_api_key
        ).bind_tools(self.tools)
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
    
    def _create_workflow(self) -> StateGraph:
        """Create the LangGraph workflow with tool-calling"""
        workflow = StateGraph(AgentState)
        
        # Add nodes
        workflow.add_node("agent", self._agent_node)
        workflow.add_node("tools", self._tool_node)
        workflow.add_node("generate_response", self._generate_response_node)
        
        # Define workflow
        workflow.add_edge(START, "agent")
        workflow.add_conditional_edges(
            "agent",
            self._should_continue,
            {
                "continue": "tools",
                "end": "generate_response"
            }
        )
        workflow.add_edge("tools", "agent")
        workflow.add_edge("generate_response", END)
        
        return workflow
    
    def _should_continue(self, state: AgentState) -> Literal["continue", "end"]:
        """Determine if agent should continue with tool calls"""
        last_message = state["messages"][-1]
        if isinstance(last_message, AIMessage) and last_message.tool_calls:
            logger.info("ROUTING: Agent has tool calls to execute -> continuing to TOOLS")
            return "continue"
        else:
            logger.info("ROUTING: No tool calls found -> ending workflow and generating response")
            return "end"
    
    async def _agent_node(self, state: AgentState) -> AgentState:
        """Main agent node that decides what tools to use"""
        logger.info("AGENT_NODE: Starting agent processing")
        
        try:
            # Build context for the agent
            cooking_session = state["cooking_session"]
            logger.info(f"AGENT_NODE: Processing query: '{state['current_query']}'")
            logger.info(f"AGENT_NODE: Recipe context: {cooking_session.recipe.title}")
            
            # Create system message with cooking context
            system_context = self._build_system_context(cooking_session)
            logger.info(f"AGENT_NODE: Built system context with {len(system_context)} characters")
            
            # Get current messages or initialize
            messages = state.get("messages", [])
            if not messages:
                messages = [
                    HumanMessage(content=f"System context: {system_context}"),
                    HumanMessage(content=state["current_query"])
                ]
                logger.info("AGENT_NODE: Initialized conversation with system context")
            else:
                logger.info(f"AGENT_NODE: Continuing conversation with {len(messages)} existing messages")
            
            # Call LLM with tools
            logger.info("AGENT_NODE: Calling LLM with tools...")
            response = await self.llm.ainvoke(messages)
            messages.append(response)
            
            # Log tool calls if any
            if hasattr(response, 'tool_calls') and response.tool_calls:
                tool_names = [tc.get('name', 'unknown') for tc in response.tool_calls]
                logger.info(f"AGENT_NODE: LLM decided to call {len(response.tool_calls)} tools: {', '.join(tool_names)}")
                for i, tc in enumerate(response.tool_calls):
                    logger.info(f"AGENT_NODE: Tool {i+1}: {tc.get('name', 'unknown')} with args: {tc.get('args', {})}")
            else:
                logger.info("AGENT_NODE: LLM provided direct response without tool calls")
            
            state["messages"] = messages
            logger.info("AGENT_NODE: Agent processing completed successfully")
            
        except Exception as e:
            logger.error(f"AGENT_NODE: Error during agent processing: {str(e)}")
            state["error"] = f"Agent error: {str(e)}"
        
        return state
    
    async def _tool_node(self, state: AgentState) -> AgentState:
        """Execute tools and update state"""
        logger.info("TOOL_NODE: Starting tool execution")
        
        try:
            last_message = state["messages"][-1]
            if isinstance(last_message, AIMessage) and last_message.tool_calls:
                logger.info(f"TOOL_NODE: Executing {len(last_message.tool_calls)} tool calls")
                tool_messages = []
                
                for i, tool_call in enumerate(last_message.tool_calls):
                    tool_name = tool_call["name"]
                    tool_id = tool_call["id"]
                    logger.info(f"TOOL_NODE: Executing tool {i+1}/{len(last_message.tool_calls)}: {tool_name}")
                    logger.info(f"TOOL_NODE: Tool args: {tool_call.get('args', {})}")
                    
                    # Execute tool and get result
                    if tool_name == "get_cooking_guidance":
                        logger.info("TOOL_NODE: Using special cooking guidance handler")
                        tool_result = await self._execute_cooking_guidance(state, tool_call)
                    else:
                        # Execute regular tools by finding the tool and calling it
                        tool_func = None
                        for tool in self.tools:
                            if tool.name == tool_name:
                                tool_func = tool
                                break
                        
                        if tool_func:
                            logger.info(f"TOOL_NODE: Found tool function for {tool_name}, executing...")
                            tool_result = await tool_func.ainvoke(tool_call["args"])
                        else:
                            logger.error(f"TOOL_NODE: Tool {tool_name} not found in available tools")
                            tool_result = f"Error: Tool {tool_name} not found"
                    
                    logger.info(f"TOOL_NODE: Tool {tool_name} result: {str(tool_result)[:200]}...")
                    
                    # Process special tool results (timer commands)
                    self._process_tool_result(state, tool_call, tool_result)
                    
                    # Add tool message to conversation
                    tool_messages.append(
                        ToolMessage(
                            content=str(tool_result),
                            tool_call_id=tool_id
                        )
                    )
                
                state["messages"].extend(tool_messages)
                logger.info(f"TOOL_NODE: All {len(last_message.tool_calls)} tools executed successfully")
            else:
                logger.warning("TOOL_NODE: Called but no tool calls found in last message")
                
        except Exception as e:
            logger.error(f"TOOL_NODE: Error during tool execution: {str(e)}")
            state["error"] = f"Tool execution error: {str(e)}"
        
        return state
    
    async def _execute_cooking_guidance(self, state: AgentState, tool_call: Dict) -> str:
        """Execute cooking guidance using the knowledge tools"""
        try:
            knowledge_tools = KnowledgeTools()
            question = tool_call["args"]["question"]
            
            # Get cooking guidance using existing knowledge tools
            guidance = await knowledge_tools.get_cooking_knowledge(
                query=question,
                recipe_context=state["cooking_session"].recipe,
                conversation_history=state["cooking_session"].conversation_history,
                model="gpt-4o-mini"
            )
            
            return guidance
            
        except Exception as e:
            return f"I'm having trouble accessing cooking information right now. Error: {str(e)}"
    
    def _process_tool_result(self, state: AgentState, tool_call: Dict, tool_result: str):
        """Process tool results and update cooking session state"""
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
                    target_id=timer_id,  # Use the timer_id generated by the tool
                    label=label,
                    parameters={"duration_seconds": duration_seconds}
                )
                
                # Add to session
                state["cooking_session"].commands.append(command)
        
        elif tool_name == "start_timer" and tool_result.startswith("timer_started:"):
            timer_id = tool_result.split(":", 1)[1]
            command = Command(
                command_type="timer",
                action="start",
                target_id=timer_id,
                label="Start timer"
            )
            state["cooking_session"].commands.append(command)
        
        elif tool_name == "stop_timer" and tool_result.startswith("timer_stopped:"):
            timer_id = tool_result.split(":", 1)[1]
            command = Command(
                command_type="timer",
                action="stop",
                target_id=timer_id,
                label="Stop timer"
            )
            state["cooking_session"].commands.append(command)
        
        elif tool_name == "remove_timer" and tool_result.startswith("timer_removed:"):
            timer_id = tool_result.split(":", 1)[1]
            command = Command(
                command_type="timer",
                action="remove",
                target_id=timer_id,
                label="Remove timer"
            )
            state["cooking_session"].commands.append(command)
    
    async def _generate_response_node(self, state: AgentState) -> AgentState:
        """Generate final response for user"""
        logger.info("RESPONSE_NODE: Starting final response generation")
        
        try:
            # Create a summary prompt
            messages = state["messages"]
            logger.info(f"RESPONSE_NODE: Generating response based on {len(messages)} conversation messages")
            
            summary_prompt = HumanMessage(
                content="""Based on the conversation above, provide a helpful response to the user. 
                If tools were used, acknowledge what was accomplished. 
                Be concise and friendly. Focus on cooking assistance."""
            )
            
            messages_for_summary = messages + [summary_prompt]
            
            # Generate final response without tools
            llm_no_tools = ChatOpenAI(
                model="gpt-4o-mini",
                temperature=0.1,
                openai_api_key=settings.openai_api_key
            )
            
            logger.info("RESPONSE_NODE: Calling LLM for final response synthesis...")
            response = await llm_no_tools.ainvoke(messages_for_summary)
            state["final_response"] = response.content
            logger.info(f"RESPONSE_NODE: Generated final response: {response.content[:100]}...")
            
        except Exception as e:
            logger.error(f"RESPONSE_NODE: Error during response generation: {str(e)}")
            state["error"] = f"Response generation error: {str(e)}"
            state["final_response"] = "I apologize, but I encountered an error while processing your request."
        
        return state
    
    def _build_system_context(self, cooking_session: CookingSessionBase) -> str:
        """Build system context from cooking session"""
        context = f"Recipe: {cooking_session.recipe.title}\n"
        context += f"Servings: {cooking_session.recipe.servings}\n"
        context += f"Ingredients: {', '.join(cooking_session.recipe.ingredients[:5])}"
        if len(cooking_session.recipe.ingredients) > 5:
            context += f"... and {len(cooking_session.recipe.ingredients) - 5} more"
        
        # Add timer context - include both existing timers and their current status
        existing_timers = []
        if cooking_session.commands:
            # Get timer commands that have been added (have target_id set)
            for cmd in cooking_session.commands:
                if (cmd.command_type == "timer" and 
                    cmd.action == "add" and 
                    cmd.target_id and 
                    "duration_seconds" in cmd.parameters):
                    existing_timers.append({
                        "id": cmd.target_id,
                        "label": cmd.label,
                        "duration": cmd.parameters["duration_seconds"]
                    })
        
        if existing_timers:
            context += f"\n\nAvailable timers:"
            for timer in existing_timers:
                context += f"\n- Timer ID: {timer['id']}, Label: '{timer['label']}', Duration: {timer['duration']}s"
        
        if cooking_session.timer_status:
            context += f"\n\nCurrent timer status: "
            for timer in cooking_session.timer_status:
                context += f"\n- {timer.label} (ID: {timer.id}) - {timer.status}, {timer.remaining_seconds}s remaining"
        
        # Add conversation history context
        if cooking_session.conversation_history:
            recent_messages = cooking_session.conversation_history[-3:]  # Last 3 messages
            context += f"\n\nRecent conversation:\n"
            for msg in recent_messages:
                role = "User" if msg.role == "user" else "Assistant"
                context += f"{role}: {msg.content}\n"
        
        return context
    
    async def process_query(self, cooking_session: CookingSessionBase, query: str) -> Dict[str, Any]:
        """Process a cooking query and return the response with updated session"""
        
        logger.info("WORKFLOW_START: Beginning agent workflow execution")
        logger.info(f"WORKFLOW_START: Query: '{query.strip()}'")
        logger.info(f"WORKFLOW_START: Recipe: {cooking_session.recipe.title}")
        
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
            logger.info("WORKFLOW_START: Invoking compiled LangGraph workflow...")
            result = await self.compiled_agent.ainvoke(initial_state)
            logger.info("WORKFLOW_COMPLETE: Agent workflow completed successfully")
            
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
                "updated_session": updated_session,
                "suggested_actions": []
            }
            
            
            logger.info(f"WORKFLOW_COMPLETE: Final response: {final_response_data['response'][:100]}...")
            return final_response_data
            
        except Exception as e:
            logger.error(f"WORKFLOW_ERROR: Error in cooking agent workflow: {e}")
            
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
                "updated_session": cooking_session,
                "suggested_actions": []
            }
            
            logger.info("WORKFLOW_ERROR: Returning error response to client")
            return error_response_data


# Create singleton instance
cooking_agent = CookingAgent()