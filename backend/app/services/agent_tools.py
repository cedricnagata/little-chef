"""
Agent tools for cooking knowledge and assistance.
"""

from langchain_openai import ChatOpenAI
from langchain_core.prompts import ChatPromptTemplate

from app.config import settings
from app.schemas import RecipeBase
from app.prompts import get_cooking_prompts


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
    
    async def get_cooking_knowledge(self, query: str, recipe_context: RecipeBase, conversation_history: list, model: str) -> str:
        """Get cooking knowledge relevant to the query and recipe"""
        try:
            llm = self._get_llm(model)
            
            # Build context about the recipe
            context = f"Recipe: {recipe_context.title}\n"
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
            
            chain = prompt | llm
            response = await chain.ainvoke({})
            
            return response.content
            
        except Exception as e:
            return f"I'd love to help with that cooking question, but I'm having trouble accessing my knowledge right now. Could you try asking again? Error: {str(e)}"
