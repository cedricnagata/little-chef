"""
Agent router for cooking assistance and recipe intelligence
"""

from fastapi import APIRouter, HTTPException, status, Depends

from app.schemas import AgentQueryRequest, AgentQueryResponse
from app.services.cooking_agent import cooking_agent
from app.security import get_current_user_id

router = APIRouter(prefix="/agent", tags=["agent"])


@router.post("/chat", response_model=AgentQueryResponse)
async def chat_with_agent(
    request: AgentQueryRequest,
    current_user_id: str = Depends(get_current_user_id)
):
    """
    Chat with the cooking agent for cooking questions and advice.
    
    The agent can help with:
    - Cooking questions and techniques
    - General cooking advice
    - Recipe-specific guidance
    
    This endpoint is stateless - all context is provided in the cooking_session.
    """
    try:
        # Validate that we have a recipe in the session
        if not request.cooking_session.recipe:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="A recipe is required in the cooking session to use the agent"
            )
        
        # Validate that we have a query
        if not request.query or not request.query.strip():
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Query cannot be empty"
            )
        
        # Process the query with the agent
        result = await cooking_agent.process_query(
            cooking_session=request.cooking_session,
            query=request.query
        )
        
        return AgentQueryResponse(
            response=result["response"],
            updated_session=result["updated_session"]
        )
        
    except HTTPException:
        # Re-raise HTTP exceptions
        raise
    except Exception as e:
        # Handle unexpected errors
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"An error occurred while processing your request: {str(e)}"
        )


@router.get("/health")
async def agent_health_check(current_user_id: str = Depends(get_current_user_id)):
    """Health check for the agent service"""
    try:
        # Basic check that the agent can be initialized
        agent = cooking_agent
        return {
            "status": "healthy",
            "message": "Cooking agent is operational",
            "agent_available": agent is not None
        }
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Agent service is not available: {str(e)}"
        )
