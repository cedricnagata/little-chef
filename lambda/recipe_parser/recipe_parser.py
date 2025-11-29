"""
Recipe parsing service using LangChain with structured output for intelligent recipe extraction
"""

import json
import base64
import requests
import os
import logging
from typing import Dict, Any, Optional, Tuple, List
from langchain_openai import ChatOpenAI
from langchain_core.output_parsers import PydanticOutputParser
from langchain_core.prompts import ChatPromptTemplate

import sys
sys.path.append(os.path.join(os.path.dirname(__file__), '..'))

logger = logging.getLogger(__name__)

from shared.schemas import RecipeBase, RecipeParseResponse
from prompts import RECIPE_PARSING_PROMPT, IMAGE_RECIPE_PARSING_PROMPT, RECIPE_FORMAT_INSTRUCTIONS


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
            openai_key = os.environ.get('OPENAI_API_KEY')
            if not openai_key:
                raise ValueError("OpenAI API key is required for recipe parsing")

            self._llm = ChatOpenAI(
                model="gpt-5-mini",
                temperature=0.1,
                openai_api_key=openai_key
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
            self._prompt_template = ChatPromptTemplate.from_template(RECIPE_PARSING_PROMPT)
        return self._prompt_template

    async def _parse_with_langchain(self, content, source_type: str, source_info: str = "") -> Tuple[RecipeBase, float, List[str]]:
        """Parse recipe content using LangChain with structured output"""

        try:
            from langchain_core.messages import HumanMessage

            # For both text and multimodal content, use the chain but construct messages appropriately
            if isinstance(content, str):
                # Text content - use prompt template chain normally
                chain = self.prompt_template | self.llm | self.parser
                recipe = await chain.ainvoke({
                    "content": content,
                    "source_type": source_type,
                    "source_info": source_info,
                    "format_instructions": self.parser.get_format_instructions()
                })
            else:
                # Multimodal content - use LLM + parser chain (skip prompt template)
                # The content already includes the prompt text as the first element
                message = HumanMessage(content=content)
                chain = self.llm | self.parser
                recipe = await chain.ainvoke([message])

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

        except json.JSONDecodeError as e:
            raise RecipeParsingError(f"Failed to parse response as JSON: {str(e)}")
        except Exception as e:
            raise RecipeParsingError(f"LangChain parsing failed: {str(e)}")


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

            # Prepare multimodal content for the LLM
            multimodal_content = [{
                "type": "text",
                "text": IMAGE_RECIPE_PARSING_PROMPT
            }]

            # Add all images to the content
            for base64_image in base64_images:
                multimodal_content.append({
                    "type": "image_url",
                    "image_url": {
                        "url": f"data:image/jpeg;base64,{base64_image}"
                    }
                })

            # Use the unified parsing method with multimodal content
            parsed_recipe, confidence, warnings = await self._parse_with_langchain(
                multimodal_content,
                source_type="image"
            )

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
            firecrawl_api_url = os.environ.get('FIRECRAWL_API_URL', 'https://api.firecrawl.dev/v1/scrape')
            firecrawl_api_key = os.environ.get('FIRECRAWL_API_KEY')

            if not firecrawl_api_key:
                raise RecipeParsingError("Firecrawl API key not configured")

            payload = {
              "url": url,
              "formats": ["markdown"]
            }

            headers = {
                "Authorization": f"Bearer {firecrawl_api_key}",
                "Content-Type": "application/json"
            }

            response = requests.post(firecrawl_api_url, json=payload, headers=headers)
            response_json = response.json()

            # Firecrawl returns a Document object
            if not response_json.get('success'):
                error_msg = response_json.get('error', 'Unknown error')
                logger.error(f"Firecrawl API error: {error_msg}")
                logger.error(f"Full response: {response_json}")
                raise RecipeParsingError(f"Failed to scrape URL: {error_msg}")

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
