"""
LangGraph-based cooking agent for intelligent recipe assistance and cooking guidance.
"""

import uuid
from datetime import datetime
from typing import Dict, Any, Optional, TypedDict
from langgraph.graph import StateGraph, START, END
from app.schemas import CookingSessionBase, Message


class AgentState(TypedDict):
    """State maintained throughout the agent workflow"""
    cooking_session: CookingSessionBase
    current_query: str
    response: str
    error: Optional[str]


class CookingAgent:
    """LangGraph-based cooking agent for recipe assistance"""
    
    def __init__(self):
        self._workflow = None
        self._compiled_agent = None
    
    @property
    def workflow(self):
        """Lazy initialization of LangGraph workflow"""
        if self._workflow is None:
            self._workflow = self._create_workflow()
        return self._workflow
    
    @property
    def compiled_agent(self):
        """Lazy initialization of compiled agent"""
        if self._compiled_agent is None:
            self._compiled_agent = self.workflow.compile()
        return self._compiled_agent
    
    def _create_workflow(self) -> StateGraph:
        """Create the LangGraph workflow for cooking assistance"""
        workflow = StateGraph(AgentState)
        
        # Add agent nodes
        workflow.add_node("answer_question", self._answer_question_node)
        workflow.add_node("error_handler", self._error_handler_node)
        
        # Simple workflow: straight to answering questions
        workflow.add_edge(START, "answer_question")
        workflow.add_edge("answer_question", END)
        workflow.add_edge("error_handler", END)
        
        return workflow
    
    async def process_query(self, cooking_session: CookingSessionBase, query: str) -> Dict[str, Any]:
        """Process a cooking query and return the response with updated session"""
        
        # Initialize agent state
        initial_state: AgentState = {
            "cooking_session": cooking_session,
            "current_query": query.strip(),
            "response": "",
            "error": None
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
                content=result["response"],
                timestamp=datetime.now()
            )
            updated_session.conversation_history.append(assistant_message)
            
            return {
                "response": result["response"],
                "updated_session": updated_session,
                "suggested_actions": []
            }
            
        except Exception as e:
            # Fallback error response
            error_message = f"I encountered an error while processing your request: {str(e)}"
            
            # Still update conversation history with error
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
                content=error_message,
                timestamp=datetime.now()
            )
            cooking_session.conversation_history.append(error_assistant_message)
            
            return {
                "response": error_message,
                "updated_session": cooking_session,
                "suggested_actions": []
            }
    
    # ===== Node Implementations =====
    
    async def _answer_question_node(self, state: AgentState) -> AgentState:
        """Answer general cooking questions using recipe context"""
        try:
            from app.services.agent_tools import KnowledgeTools
            
            knowledge_tools = KnowledgeTools()
            
            # Get user's preferred model
            model_name = state["cooking_session"].user_preferences.llm_model or "gpt-5-mini"
            
            # Get cooking knowledge
            response = await knowledge_tools.get_cooking_knowledge(
                query=state["current_query"],
                recipe_context=state["cooking_session"].recipe,
                modifications=state["cooking_session"].modifications,
                conversation_history=state["cooking_session"].conversation_history,
                model=model_name
            )
            
            state["response"] = response
            
        except Exception as e:
            state["error"] = f"Error getting cooking knowledge: {str(e)}"
        
        return state
    
    async def _error_handler_node(self, state: AgentState) -> AgentState:
        """Handle errors gracefully"""
        error_msg = state.get("error", "An unknown error occurred")
        state["response"] = f"I apologize, but I encountered an issue: {error_msg}. Please try rephrasing your question."
        return state


# Global agent instance
cooking_agent = CookingAgent()
