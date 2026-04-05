//
//  LocalRecipeParser.swift
//  little-chef
//
//  Recipe parser using local LLM, web scraping, and OCR
//

import Foundation
import UIKit

@MainActor
class LocalRecipeParser: ObservableObject {
    private let llmService: LLMService
    private let webScraper: WebScraperService
    private let ocrService: OCRService

    @Published var isProcessing = false
    @Published var progress: Double = 0.0

    convenience init(llmService: LLMService) {
        self.init(llmService: llmService, webScraper: .shared, ocrService: .shared)
    }

    init(llmService: LLMService, webScraper: WebScraperService, ocrService: OCRService) {
        self.llmService = llmService
        self.webScraper = webScraper
        self.ocrService = ocrService
    }

    // MARK: - Public Methods

    func parseFromURL(_ url: String) async throws -> RecipeParseResponse {
        isProcessing = true
        progress = 0.1
        defer { isProcessing = false; progress = 1.0 }

        let webContent = try await webScraper.scrapeRecipe(from: url)
        progress = 0.3

        let recipeData = try await parseWithLLM(text: webContent, sourceUrl: url)
        progress = 1.0

        let (confidence, warnings) = evaluateRecipe(recipeData)
        return RecipeParseResponse(recipe: recipeData, confidence: confidence, warnings: warnings)
    }

    func parseFromText(_ text: String) async throws -> RecipeParseResponse {
        isProcessing = true
        progress = 0.2
        defer { isProcessing = false; progress = 1.0 }

        let recipeData = try await parseWithLLM(text: text, sourceUrl: nil)
        progress = 1.0

        let (confidence, warnings) = evaluateRecipe(recipeData)
        return RecipeParseResponse(recipe: recipeData, confidence: confidence, warnings: warnings)
    }

    func parseFromImages(_ images: [UIImage]) async throws -> RecipeParseResponse {
        isProcessing = true
        progress = 0.1
        defer { isProcessing = false; progress = 1.0 }

        guard !images.isEmpty else { throw RecipeParserError.noImagesProvided }

        let extractedText = try await ocrService.extractText(from: images)
        progress = 0.4

        guard !extractedText.isEmpty else { throw RecipeParserError.noTextExtracted }

        let recipeData = try await parseWithLLM(text: extractedText, sourceUrl: nil)
        progress = 1.0

        let (confidence, warnings) = evaluateRecipe(recipeData)
        return RecipeParseResponse(recipe: recipeData, confidence: confidence, warnings: warnings)
    }

    // MARK: - Private Methods

    private func parseWithLLM(text: String, sourceUrl: String?) async throws -> RecipeData {
        let prompt = """
        Extract the recipe from the text below into JSON. Return ONLY the JSON object.

        Example output:
        {"title": "Pasta Carbonara", "description": "Classic Roman pasta dish", "servings": 4, "prep_time": 10, "cook_time": 20, "ingredients": ["400g spaghetti", "200g guanciale", "4 egg yolks", "100g pecorino"], "instructions": ["Boil pasta in salted water until al dente.", "Cut guanciale into strips and fry until crispy.", "Mix egg yolks with grated pecorino.", "Toss drained pasta with guanciale, then stir in egg mixture off heat."], "tags": ["italian", "pasta"], "cuisine_type": "Italian", "difficulty": "medium"}

        IMPORTANT:
        - Each instruction must be the actual step text only, NOT prefixed with numbers like "Step 1:" or "1."
        - Do NOT duplicate or number steps. Just the plain instruction text.
        - prep_time and cook_time MUST be integers representing MINUTES. For example: 1 hour = 60, 1.5 hours = 90, 30 minutes = 30. Do NOT use hours or seconds.
        - Use null for unknown fields.
        - difficulty must be "easy", "medium", or "hard"

        Text:
        \(text.prefix(3000))
        """

        let response = try await llmService.generateChatCompletion(
            messages: [
                ChatMessage(role: .system, content: "You are a recipe extraction tool. Output only valid JSON. No commentary, no markdown, no numbering of steps.")
            ,
                ChatMessage(role: .user, content: prompt)
            ],
            temperature: 0.2,
            maxTokens: 1024
        )

        var recipeData = try parseRecipeJSON(from: response)

        if let sourceUrl {
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
    }

    private func parseRecipeJSON(from response: String) throws -> RecipeData {
        // Find JSON in response
        guard let jsonStart = response.firstIndex(of: "{"),
              let jsonEnd = response.lastIndex(of: "}") else {
            throw RecipeParserError.invalidJSONResponse
        }

        var jsonString = String(response[jsonStart...jsonEnd])

        // Fix common LLM JSON issues
        jsonString = jsonString
            .replacingOccurrences(of: ",\\s*}", with: "}", options: .regularExpression)  // trailing commas
            .replacingOccurrences(of: ",\\s*]", with: "]", options: .regularExpression)  // trailing commas in arrays

        guard let jsonData = jsonString.data(using: .utf8) else {
            throw RecipeParserError.invalidJSONResponse
        }

        let decoder = JSONDecoder()

        do {
            var recipe = try decoder.decode(RecipeData.self, from: jsonData)
            // Strip numbered prefixes like "1. ", "Step 1: ", "1: " from instructions
            recipe = RecipeData(
                title: recipe.title,
                description: recipe.description,
                servings: recipe.servings,
                prepTime: recipe.prepTime,
                cookTime: recipe.cookTime,
                ingredients: recipe.ingredients,
                instructions: recipe.instructions.map { step in
                    step.replacingOccurrences(
                        of: "^\\s*(?:step\\s*)?\\d+[.:)\\-]\\s*",
                        with: "",
                        options: [.regularExpression, .caseInsensitive]
                    )
                }.filter { !$0.isEmpty },
                tags: recipe.tags,
                sourceUrl: recipe.sourceUrl,
                cuisineType: recipe.cuisineType,
                difficulty: recipe.difficulty
            )
            return recipe
        } catch {
            print("JSON decoding error: \(error)")
            throw RecipeParserError.invalidJSONResponse
        }
    }

    private func evaluateRecipe(_ recipe: RecipeData) -> (confidence: Double, warnings: [String]) {
        var confidence: Double = 1.0
        var warnings: [String] = []

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
        if recipe.prepTime == nil { confidence -= 0.05 }
        if recipe.cookTime == nil { confidence -= 0.05 }

        return (max(0.0, min(1.0, confidence)), warnings)
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
            return "Could not read text from images. Ensure images contain readable text."
        case .invalidJSONResponse:
            return "Failed to parse recipe. Please try again."
        case .parsingFailed(let error):
            return "Recipe parsing failed: \(error.localizedDescription)"
        }
    }
}
