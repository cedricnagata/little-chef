"""
Prompts for recipe parsing
"""

# Recipe parsing prompt template for text and URL content
RECIPE_PARSING_PROMPT = """
You are an expert recipe parser. Extract a complete recipe from the following {source_type} content and return ONLY a valid JSON object with this exact structure:

{{
    "title": "Recipe Title",
    "description": "Brief description of the dish",
    "ingredients": ["ingredient 1 with quantity", "ingredient 2 with quantity", "..."],
    "instructions": ["step 1", "step 2", "..."],
    "prep_time": 15,
    "cook_time": 30,
    "servings": 4,
    "difficulty": "easy",
    "tags": ["tag1", "tag2"],
    "cuisine_type": "cuisine name",
    "source_url": "{source_info}"
}}

Guidelines:
- Extract ALL ingredients with quantities and units when available
- List ALL cooking steps in the correct order
- Estimate reasonable prep/cook times if not explicitly stated
- Choose difficulty from: "easy", "medium", or "hard"
- Add relevant tags (cuisine type, dietary restrictions, meal type, cooking method, etc.)
- Include cuisine type if identifiable
- Preserve source URL if provided

Content to parse:
{content}

Return ONLY the JSON object, no other text.
"""

# Recipe parsing prompt for image content
IMAGE_RECIPE_PARSING_PROMPT = """
Analyze these recipe images and extract a complete recipe. If there are multiple images, combine information from all of them. Return ONLY a valid JSON object with this exact structure:

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

Return ONLY the JSON object, no other text.
"""

# Format instructions for structured output
RECIPE_FORMAT_INSTRUCTIONS = """
{format_instructions}

Important: Return ONLY valid JSON. Do not include any explanations, markdown formatting, or additional text.
"""
