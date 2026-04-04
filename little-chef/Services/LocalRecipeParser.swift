//
//  LocalRecipeParser.swift
//  little-chef
//
//  Unified recipe parser using local LLM, web scraping, and OCR
//  Replaces backend recipe_parser.py service
//

import Foundation
import UIKit

/// Service for parsing recipes from various input sources
@MainActor
class LocalRecipeParser: ObservableObject {
    // MARK: - Dependencies
    private let llmService: LLMService
    private let webScraper: WebScraperService
    private let ocrService: OCRService

    // MARK: - Published State
    @Published var isProcessing = false
    @Published var progress: Double = 0.0

    // MARK: - Initialization

    init(
        llmService: LLMService = .shared,
        webScraper: WebScraperService = .shared,
        ocrService: OCRService = .shared
    ) {
        self.llmService = llmService
        self.webScraper = webScraper
        self.ocrService = ocrService
    }

    // MARK: - Public Methods

    /// Parse recipe from URL
    func parseFromURL(_ url: String) async throws -> RecipeParseResponse {
        isProcessing = true
        progress = 0.0
        defer {
            isProcessing = false
            progress = 1.0
        }

        // Step 1: Scrape web content (30%)
        progress = 0.1
        let webContent = try await webScraper.scrapeRecipe(from: url)
        progress = 0.3

        // Step 2: Parse with LLM (70%)
        let recipeData = try await parseWithLLM(text: webContent, sourceUrl: url)
        progress = 1.0

        // Step 3: Calculate confidence and warnings
        let (confidence, warnings) = evaluateRecipe(recipeData)

        return RecipeParseResponse(
            recipe: recipeData,
            confidence: confidence,
            warnings: warnings
        )
    }

    /// Parse recipe from text
    func parseFromText(_ text: String) async throws -> RecipeParseResponse {
        isProcessing = true
        progress = 0.0
        defer {
            isProcessing = false
            progress = 1.0
        }

        // Parse with LLM
        progress = 0.2
        let recipeData = try await parseWithLLM(text: text, sourceUrl: nil)
        progress = 1.0

        // Calculate confidence and warnings
        let (confidence, warnings) = evaluateRecipe(recipeData)

        return RecipeParseResponse(
            recipe: recipeData,
            confidence: confidence,
            warnings: warnings
        )
    }

    /// Parse recipe from images
    func parseFromImages(_ images: [UIImage]) async throws -> RecipeParseResponse {
        isProcessing = true
        progress = 0.0
        defer {
            isProcessing = false
            progress = 1.0
        }

        guard !images.isEmpty else {
            throw RecipeParserError.noImagesProvided
        }

        // Step 1: Extract text from images using OCR (40%)
        progress = 0.1
        let extractedText = try await ocrService.extractText(from: images)
        progress = 0.4

        guard !extractedText.isEmpty else {
            throw RecipeParserError.noTextExtracted
        }

        // Step 2: Parse with LLM (60%)
        let recipeData = try await parseWithLLM(text: extractedText, sourceUrl: nil)
        progress = 1.0

        // Step 3: Calculate confidence and warnings
        let (confidence, warnings) = evaluateRecipe(recipeData)

        return RecipeParseResponse(
            recipe: recipeData,
            confidence: confidence,
            warnings: warnings
        )
    }

    // MARK: - Private Methods

    private func parseWithLLM(text: String, sourceUrl: String?) async throws -> RecipeData {
        let prompt = buildRecipeExtractionPrompt(text: text)

        // Generate structured response
        let response = try await llmService.generateChatCompletion(
            messages: [
                ChatMessage(role: .system, content: "You are a recipe extraction assistant. Extract recipe information from the provided text and return it as JSON."),
                ChatMessage(role: .user, content: prompt)
            ],
            temperature: 0.3, // Lower temperature for more consistent output
            maxTokens: 2048
        )

        // Parse JSON response
        let recipeData = try parseRecipeJSON(from: response, sourceUrl: sourceUrl)

        return recipeData
    }

    private func buildRecipeExtractionPrompt(text: String) -> String {
        return """
        Extract recipe information from the following text and return it as a JSON object with this exact structure:

        {
            "title": "Recipe title",
            "description": "Brief description (optional)",
            "servings": 4,
            "prep_time": 15,
            "cook_time": 30,
            "ingredients": ["ingredient 1", "ingredient 2", ...],
            "instructions": ["step 1", "step 2", ...],
            "tags": ["tag1", "tag2", ...],
            "cuisine_type": "Italian",
            "difficulty": "easy"
        }

        Guidelines:
        - Extract all ingredients as a list
        - Extract all instructions/steps as a list
        - Times should be in minutes (convert if needed)
        - If information is missing, use null for optional fields
        - Difficulty should be: "easy", "medium", or "hard"
        - Tags should include relevant keywords (e.g., "vegetarian", "quick", "dessert")

        Text to parse:
        \(text)

        Return ONLY the JSON object, no additional text.
        """
    }

    private func parseRecipeJSON(from response: String, sourceUrl: String?) throws -> RecipeData {
        // Extract JSON from response (may have text before/after)
        guard let jsonStart = response.firstIndex(of: "{"),
              let jsonEnd = response.lastIndex(of: "}") else {
            throw RecipeParserError.invalidJSONResponse
        }

        let jsonString = String(response[jsonStart...jsonEnd])

        guard let jsonData = jsonString.data(using: .utf8) else {
            throw RecipeParserError.invalidJSONResponse
        }

        // Custom decoder to handle both snake_case and camelCase
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            var recipeData = try decoder.decode(RecipeData.self, from: jsonData)

            // Add source URL if provided
            if sourceUrl != nil {
                recipeData = RecipeData(
                    title: recipeData.title,
                    description: recipeData.description,
                    servings: recipeData.servings,
                    prepTime: recipeData.prepTime,
                    cookTime: recipeData.cookTime,
                    ingredients: recipeData.ingredients,
                    instructions: recipeData.instructions,
                    tags: recipeData.tags,
                    sourceUrl: sourceUrl,
                    cuisineType: recipeData.cuisineType,
                    difficulty: recipeData.difficulty
                )
            }

            return recipeData
        } catch {
            print("JSON decoding error: \(error)")
            throw RecipeParserError.invalidJSONResponse
        }
    }

    private func evaluateRecipe(_ recipe: RecipeData) -> (confidence: Double, warnings: [String]) {
        var confidence: Double = 1.0
        var warnings: [String] = []

        // Check required fields
        if recipe.title.isEmpty {
            confidence -= 0.5
            warnings.append("Missing title")
        }

        if recipe.ingredients.isEmpty {
            confidence -= 0.3
            warnings.append("Missing ingredients")
        }

        if recipe.instructions.isEmpty {
            confidence -= 0.3
            warnings.append("Missing instructions")
        }

        // Check optional fields
        if recipe.description == nil || recipe.description?.isEmpty == true {
            confidence -= 0.05
            warnings.append("Missing description")
        }

        if recipe.prepTime == nil {
            confidence -= 0.05
            warnings.append("Missing prep time")
        }

        if recipe.cookTime == nil {
            confidence -= 0.05
            warnings.append("Missing cook time")
        }

        if recipe.cuisineType == nil || recipe.cuisineType?.isEmpty == true {
            confidence -= 0.05
        }

        if recipe.difficulty == nil {
            confidence -= 0.05
        }

        // Ensure confidence is between 0 and 1
        confidence = max(0.0, min(1.0, confidence))

        return (confidence, warnings)
    }
}

// MARK: - Error Types

enum RecipeParserError: LocalizedError {
    case noImagesProvided
    case noTextExtracted
    case invalidJSONResponse
    case parsingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noImagesProvided:
            return "No images provided for parsing"
        case .noTextExtracted:
            return "Failed to extract text from images. Please ensure images contain readable text."
        case .invalidJSONResponse:
            return "Failed to parse recipe from LLM response. Please try again."
        case .parsingFailed(let error):
            return "Recipe parsing failed: \(error.localizedDescription)"
        }
    }
}
