"""
Recipe parsing service using LangChain with structured output for intelligent recipe extraction
"""

import json
import base64
import requests
from typing import Dict, Any, Optional, Tuple, List
from langchain_openai import ChatOpenAI
from langchain_core.output_parsers import PydanticOutputParser
from langchain_core.prompts import ChatPromptTemplate

from app.config import settings
from app.schemas import RecipeBase, RecipeParseResponse


class RecipeParsingError(Exception):
    """Custom exception for recipe parsing errors"""
    pass


class RecipeParser:
    """Service for parsing recipes from various sources using LangChain with structured output"""
    
    def __init__(self):
        self._llm = None
        self._parser = None
        self._prompt_template = None
    
    @property
    def llm(self):
        """Lazy initialization of LangChain LLM"""
        if self._llm is None:
            if not settings.openai_api_key:
                raise ValueError("OpenAI API key is required for recipe parsing")
            
            self._llm = ChatOpenAI(
                model="gpt-5-mini",
                temperature=0.1,
                openai_api_key=settings.openai_api_key
            )
        return self._llm
    
    @property
    def parser(self):
        """Lazy initialization of Pydantic output parser"""
        if self._parser is None:
            self._parser = PydanticOutputParser(pydantic_object=RecipeBase)
        return self._parser
    
    
    @property
    def prompt_template(self):
        """Lazy initialization of prompt template"""
        if self._prompt_template is None:
            template = """You are an expert chef and recipe analyzer. Your task is to extract and standardize recipe information from the provided content.

Extract the recipe information according to these guidelines:

1. **Title**: Extract the recipe name/title
2. **Description**: Brief description if available (optional)
3. **Servings**: Number of people this recipe serves (default to 4 if unclear)
4. **Prep Time**: Preparation time in minutes (convert from hours/other units)
5. **Cook Time**: Cooking time in minutes (convert from hours/other units)
6. **Ingredients**: 
   - List each ingredient with quantity and unit
   - Keep original formatting but ensure clarity
   - Include all ingredients mentioned
7. **Instructions**:
   - Break into clear, sequential steps
   - Each step should be actionable
   - Maintain logical cooking order
8. **Tags**: Add relevant tags like cuisine type, meal category, dietary restrictions
9. **Cuisine Type**: Identify the cuisine style if apparent
10. **Difficulty**: Assess as "easy", "medium", or "hard" based on technique complexity

Content to parse:
{content}

{format_instructions}"""
            
            self._prompt_template = ChatPromptTemplate.from_template(template)
        return self._prompt_template

    async def _parse_with_langchain(self, content: str, source_type: str, source_info: str = "") -> Tuple[RecipeBase, float, List[str]]:
        """Parse recipe content using LangChain with structured output"""
        
        try:
            # Create the parsing chain
            chain = self.prompt_template | self.llm | self.parser
            
            # Invoke the chain with the content
            recipe = await chain.ainvoke({
                "content": content,
                "format_instructions": self.parser.get_format_instructions()
            })
            
            # Add source URL if parsing from URL
            if source_type == "url" and source_info:
                recipe.source_url = source_info
            
            # Convert to dict for validation and confidence calculation
            recipe_data = recipe.model_dump()
            
            # Calculate confidence based on completeness
            confidence = self._calculate_confidence(recipe_data)
            
            # Generate warnings for missing or questionable data
            warnings = self._generate_warnings(recipe_data, source_type)
            
            return recipe, confidence, warnings
            
        except Exception as e:
            raise RecipeParsingError(f"LangChain parsing failed: {str(e)}")

    async def _parse_images_with_langchain(self, base64_images: List[str]) -> Tuple[RecipeBase, float, List[str]]:
        """Parse recipe from multiple images using GPT-5-Mini Vision"""
        
        try:
            from langchain_core.messages import HumanMessage
            
            # Create vision-enabled LLM for image processing
            vision_llm = ChatOpenAI(
                model="gpt-5-mini",
                temperature=0.1,
                openai_api_key=settings.openai_api_key
            )
            
            # Prepare the message content with multiple images
            content = [{
                "type": "text",
                "text": f"""Analyze these recipe images and extract a complete recipe. If there are multiple images, combine information from all of them. Return ONLY a valid JSON object with this exact structure:

{{
    "title": "Recipe Title",
    "description": "Brief description of the dish",
    "ingredients": ["ingredient 1", "ingredient 2", "..."],
    "instructions": ["step 1", "step 2", "..."],
    "prep_time": 15,
    "cook_time": 30,
    "servings": 4,
    "difficulty": "easy",
    "tags": ["tag1", "tag2"]
}}

Please:
- Extract ALL visible ingredients with quantities and units
- List ALL cooking steps in order
- Estimate reasonable prep/cook times if not visible
- Choose difficulty: "easy", "medium", or "hard"
- Add relevant tags (cuisine type, dietary restrictions, meal type, etc.)
- If the image is unclear or doesn't contain a recipe, create a generic recipe template

Return ONLY the JSON object, no other text."""
            }]
            
            # Add all images to the content
            for i, base64_image in enumerate(base64_images):
                content.append({
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:image/jpeg;base64,{base64_image}"
                    }
                })
            
            image_message = HumanMessage(content=content)
            
            # Get response from vision model
            response = await vision_llm.ainvoke([image_message])
            response_content = response.content.strip()
            
            # Parse the JSON response
            try:
                if response_content.startswith("```json"):
                    response_content = response_content.replace("```json", "").replace("```", "").strip()
                elif response_content.startswith("```"):
                    response_content = response_content.replace("```", "").strip()
                
                recipe_data = json.loads(response_content)
                
                # Create RecipeBase object
                parsed_recipe = RecipeBase(
                    title=recipe_data.get("title", "Recipe from Image"),
                    description=recipe_data.get("description"),
                    ingredients=recipe_data.get("ingredients", []),
                    instructions=recipe_data.get("instructions", []),
                    prep_time=recipe_data.get("prep_time"),
                    cook_time=recipe_data.get("cook_time"),
                    servings=recipe_data.get("servings", 4),
                    difficulty=recipe_data.get("difficulty"),
                    tags=recipe_data.get("tags", [])
                )
                
                # Calculate confidence based on completeness
                confidence = 0.9  # High confidence for vision model
                if not parsed_recipe.ingredients or len(parsed_recipe.ingredients) < 2:
                    confidence -= 0.2
                if not parsed_recipe.instructions or len(parsed_recipe.instructions) < 2:
                    confidence -= 0.2
                if not parsed_recipe.title or parsed_recipe.title == "Recipe from Image":
                    confidence -= 0.1
                
                warnings = []
                if confidence < 0.7:
                    warnings.append("Image quality may be low - please review extracted recipe carefully")
                
                return parsed_recipe, confidence, warnings
                
            except json.JSONDecodeError as e:
                # Fallback if JSON parsing fails
                raise RecipeParsingError(f"Failed to parse vision model response as JSON: {str(e)}")
            
        except Exception as e:
            raise RecipeParsingError(f"Image parsing with GPT-5-Mini Vision failed: {str(e)}")

    async def parse_from_url(self, url: str) -> RecipeParseResponse:
        """Parse recipe from a URL using multiple strategies"""
        if not url or not url.strip():
            raise RecipeParsingError("URL cannot be empty")
        
        url = url.strip()
        
        try:
            # Fetch the webpage content
            content = await self._fetch_url_content(url)
            
            # Extract recipe using LangChain
            parsed_recipe, confidence, warnings = await self._parse_with_langchain(
                content, 
                source_type="url",
                source_info=url
            )
            
            return RecipeParseResponse(
                recipe=parsed_recipe,
                confidence=confidence,
                warnings=warnings
            )
            
        except Exception as e:
            raise RecipeParsingError(f"Failed to parse recipe from URL: {str(e)}")

    async def parse_from_text(self, text: str) -> RecipeParseResponse:
        """Parse recipe from plain text using LangChain"""
        try:
            parsed_recipe, confidence, warnings = await self._parse_with_langchain(
                text,
                source_type="text"
            )
            
            return RecipeParseResponse(
                recipe=parsed_recipe,
                confidence=confidence,
                warnings=warnings
            )
            
        except Exception as e:
            raise RecipeParsingError(f"Failed to parse recipe from text: {str(e)}")

    async def parse_from_image(self, base64_images: List[str]) -> RecipeParseResponse:
        """Parse recipe from multiple images using LangChain with vision"""
        try:
            # Validate all base64 images
            for i, base64_image in enumerate(base64_images):
                if not self._is_valid_base64_image(base64_image):
                    raise RecipeParsingError(f"Invalid base64 image format for image {i+1}")
            
            parsed_recipe, confidence, warnings = await self._parse_images_with_langchain(base64_images)
            
            return RecipeParseResponse(
                recipe=parsed_recipe,
                confidence=confidence,
                warnings=warnings
            )
            
        except Exception as e:
            raise RecipeParsingError(f"Failed to parse recipe from image: {str(e)}")


    # Helper methods for recipe data processing
    
    async def _fetch_url_content(self, url: str) -> str:
        """Fetch content from URL using Firecrawl"""
        try:
            firecrawl_api_url = settings.firecrawl_api_url

            payload = {
              "url": url,
              "onlyMainContent": True,
              "maxAge": 172800000,
              "parsers": [
                "pdf"
              ],
              "formats": [
                "markdown"
              ]
            }

            headers = {
                "Authorization": f"Bearer {settings.firecrawl_api_key}",
                "Content-Type": "application/json"
            }

            response = requests.post(firecrawl_api_url, json=payload, headers=headers)
            response_json = response.json()
            
            # Firecrawl returns a Document object
            if not response_json['success']:
                raise RecipeParsingError("Failed to scrape URL: No content returned")

            if not response_json['success']:
                raise RecipeParsingError("Failed to scrape URL")

            return response_json['data']['markdown']
            
        except Exception as e:
            if isinstance(e, RecipeParsingError):
                raise
            raise RecipeParsingError(f"Failed to fetch content from URL: {str(e)}")
    

    def _validate_and_clean_recipe_data(self, data: Dict[str, Any]) -> Dict[str, Any]:
        """Validate and clean recipe data from LLM"""
        
        # Ensure required fields exist
        if not data.get('title'):
            data['title'] = "Untitled Recipe"
        
        if not data.get('ingredients') or not isinstance(data['ingredients'], list):
            raise RecipeParsingError("Recipe must have ingredients list")
        
        if not data.get('instructions') or not isinstance(data['instructions'], list):
            raise RecipeParsingError("Recipe must have instructions list")
        
        # Clean and validate fields
        data['title'] = str(data['title']).strip()[:255]
        
        # Ensure servings is a positive integer
        if not isinstance(data.get('servings'), int) or data['servings'] <= 0:
            data['servings'] = 4
        
        # Validate time fields
        for time_field in ['prep_time', 'cook_time']:
            if data.get(time_field) is not None:
                try:
                    time_val = int(data[time_field])
                    data[time_field] = max(0, min(time_val, 1440))  # Cap at 24 hours
                except (ValueError, TypeError):
                    data[time_field] = None
        
        # Clean ingredients and instructions
        data['ingredients'] = [str(ing).strip() for ing in data['ingredients'] if str(ing).strip()]
        data['instructions'] = [str(inst).strip() for inst in data['instructions'] if str(inst).strip()]
        
        # Ensure tags is a list
        if not isinstance(data.get('tags'), list):
            data['tags'] = []
        data['tags'] = [str(tag).strip().lower() for tag in data['tags'] if str(tag).strip()]
        
        # Validate difficulty
        if data.get('difficulty') not in ['easy', 'medium', 'hard']:
            data['difficulty'] = None
        
        # Clean string fields
        for field in ['description', 'cuisine_type', 'source_url']:
            if data.get(field):
                data[field] = str(data[field]).strip()
            else:
                data[field] = None
        
        return data

    def _calculate_confidence(self, recipe_data: Dict[str, Any]) -> float:
        """Calculate confidence score based on recipe completeness"""
        
        score = 0.0
        
        # Required fields (40 points)
        if recipe_data.get('title'):
            score += 10
        if recipe_data.get('ingredients') and len(recipe_data['ingredients']) > 0:
            score += 15
        if recipe_data.get('instructions') and len(recipe_data['instructions']) > 0:
            score += 15
        
        # Important fields (30 points)
        if recipe_data.get('servings'):
            score += 10
        if recipe_data.get('prep_time') is not None:
            score += 10
        if recipe_data.get('cook_time') is not None:
            score += 10
        
        # Optional fields (30 points)
        if recipe_data.get('description'):
            score += 5
        if recipe_data.get('tags') and len(recipe_data['tags']) > 0:
            score += 5
        if recipe_data.get('cuisine_type'):
            score += 5
        if recipe_data.get('difficulty'):
            score += 5
        
        # Bonus for well-formatted ingredients/instructions
        if len(recipe_data.get('ingredients', [])) >= 3:
            score += 5
        if len(recipe_data.get('instructions', [])) >= 3:
            score += 5
        
        return min(score / 100.0, 1.0)

    def _generate_warnings(self, recipe_data: Dict[str, Any], source_type: str) -> List[str]:
        """Generate warnings for missing or questionable data"""
        
        warnings = []
        
        if not recipe_data.get('prep_time'):
            warnings.append("Could not parse prep time")
        
        if not recipe_data.get('cook_time'):
            warnings.append("Could not parse cook time")
        
        if not recipe_data.get('description'):
            warnings.append("No recipe description found")
        
        if len(recipe_data.get('ingredients', [])) < 3:
            warnings.append("Recipe has very few ingredients")
        
        if len(recipe_data.get('instructions', [])) < 3:
            warnings.append("Recipe has very few instructions")
        
        if source_type == "url" and not recipe_data.get('source_url'):
            warnings.append("Could not preserve source URL")
        
        return warnings

    def _is_valid_base64_image(self, base64_string: str) -> bool:
        """Validate base64 image format"""
        try:
            # Remove data URL prefix if present
            if base64_string.startswith('data:image'):
                base64_string = base64_string.split(',')[1]
            
            # Try to decode
            decoded = base64.b64decode(base64_string)
            
            # Check for common image headers
            image_headers = [
                b'\xff\xd8\xff',  # JPEG
                b'\x89\x50\x4e\x47',  # PNG
                b'\x47\x49\x46',  # GIF
                b'\x52\x49\x46\x46',  # WebP
            ]
            
            return any(decoded.startswith(header) for header in image_headers)
            
        except Exception:
            return False
