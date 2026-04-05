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

        print("📖 [PARSER] Parsing URL: \(url)")
        let webContent: String
        do {
            webContent = try await webScraper.scrapeRecipe(from: url)
            print("📖 [PARSER] Scraped content length: \(webContent.count) chars")
        } catch {
            print("📖 [PARSER] ❌ Scraping failed: \(error.localizedDescription)")
            throw error
        }
        progress = 0.3

        var recipeData: RecipeData

        // Try direct schema.org parsing first, then always do an LLM cleanup pass
        if webContent.hasPrefix("Schema.org Recipe JSON:"),
           let parsed = try? parseSchemaOrgRecipe(from: webContent, sourceUrl: url) {
            print("📖 [PARSER] ✅ Parsed from schema.org, running LLM cleanup pass")
            if let cleaned = try? await cleanupWithLLM(schema: parsed, sourceUrl: url) {
                recipeData = cleaned
            } else {
                print("📖 [PARSER] LLM cleanup failed, using raw schema.org result")
                recipeData = parsed
            }
        } else {
            // No schema.org — full LLM parse with higher token limit
            print("📖 [PARSER] No schema.org data, falling back to LLM")
            print("📖 [PARSER] Content preview (first 500 chars):\n\(String(webContent.prefix(500)))")
            recipeData = try await parseWithLLM(text: webContent, sourceUrl: url, maxTokens: 4096)
        }

        print("📖 [PARSER] ✅ Parsed recipe: \(recipeData.title)")
        print("📖 [PARSER]   Ingredients: \(recipeData.ingredients.count), Steps: \(recipeData.instructions.count)")
        print("📖 [PARSER]   Prep: \(recipeData.prepTime?.description ?? "nil"), Cook: \(recipeData.cookTime?.description ?? "nil")")
        progress = 1.0

        let (confidence, warnings) = evaluateRecipe(recipeData)
        print("📖 [PARSER] Confidence: \(confidence), Warnings: \(warnings)")
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

    private func parseWithLLM(text: String, sourceUrl: String?, maxTokens: Int = 1024) async throws -> RecipeData {
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
        \(text.prefix(5000))
        """

        let response = try await llmService.generateChatCompletion(
            messages: [
                ChatMessage(role: .system, content: "You are a recipe extraction tool. Output only valid JSON. No commentary, no markdown, no numbering of steps.")
            ,
                ChatMessage(role: .user, content: prompt)
            ],
            temperature: 0.2,
            maxTokens: maxTokens
        )

        print("📖 [PARSER] LLM raw response (\(response.count) chars):\n\(response.prefix(1000))")

        var recipeData: RecipeData
        do {
            recipeData = try parseRecipeJSON(from: response)
        } catch {
            print("📖 [PARSER] ❌ JSON parse failed: \(error)")
            print("📖 [PARSER] Full response was:\n\(response)")
            throw error
        }

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

    // MARK: - LLM Cleanup Pass

    /// Always run an LLM pass on schema.org data to organize, clean up, and fill any gaps.
    private func cleanupWithLLM(schema: RecipeData, sourceUrl: String?) async throws -> RecipeData {
        let ingredientsList = schema.ingredients.isEmpty ? "NONE FOUND" : schema.ingredients.joined(separator: "\n- ")
        let instructionsList = schema.instructions.isEmpty ? "NONE FOUND" : schema.instructions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

        let prompt = """
        Clean up and organize this recipe data into JSON. Return ONLY the JSON object.

        Title: \(schema.title)
        Description: \(schema.description ?? "none")
        Servings: \(schema.servings)
        Prep time: \(schema.prepTime.map { "\($0) minutes" } ?? "unknown")
        Cook time: \(schema.cookTime.map { "\($0) minutes" } ?? "unknown")
        Cuisine: \(schema.cuisineType ?? "unknown")
        Tags: \(schema.tags.joined(separator: ", "))

        Ingredients:
        - \(ingredientsList)

        Instructions:
        \(instructionsList)

        Example output format:
        {"title": "Recipe Name", "description": "Short description", "servings": 4, "prep_time": 10, "cook_time": 20, "ingredients": ["ingredient 1", "ingredient 2"], "instructions": ["Do this first.", "Then do this."], "tags": ["tag1"], "cuisine_type": "Italian", "difficulty": "medium"}

        IMPORTANT:
        - Clean up ingredients: remove HTML entities, fix formatting, keep quantities
        - Clean up instructions: make each step clear and concise, remove URLs or metadata
        - Do NOT number or prefix instructions with "Step 1:" etc.
        - prep_time and cook_time MUST be integers in MINUTES
        - difficulty must be "easy", "medium", or "hard"
        - Fill in any missing fields if you can infer them
        """

        let response = try await llmService.generateChatCompletion(
            messages: [
                ChatMessage(role: .system, content: "You are a recipe organizer. Clean up and format the recipe data. Output only valid JSON."),
                ChatMessage(role: .user, content: prompt)
            ],
            temperature: 0.2,
            maxTokens: 4096
        )

        print("📖 [PARSER] LLM cleanup response (\(response.count) chars):\n\(response.prefix(500))")

        var cleaned = try parseRecipeJSON(from: response)

        // Preserve source URL
        if let sourceUrl {
            cleaned = RecipeData(
                title: cleaned.title,
                description: cleaned.description,
                servings: cleaned.servings,
                prepTime: cleaned.prepTime,
                cookTime: cleaned.cookTime,
                ingredients: cleaned.ingredients,
                instructions: cleaned.instructions,
                tags: cleaned.tags,
                sourceUrl: sourceUrl,
                cuisineType: cleaned.cuisineType,
                difficulty: cleaned.difficulty
            )
        }

        return cleaned
    }

    // MARK: - Schema.org Direct Parsing

    /// Parse a schema.org Recipe JSON directly into RecipeData — no LLM needed.
    private func parseSchemaOrgRecipe(from content: String, sourceUrl: String?) throws -> RecipeData {
        // Strip the "Schema.org Recipe JSON:\n" prefix
        let jsonString = content.replacingOccurrences(of: "Schema.org Recipe JSON:\n", with: "")

        guard let data = jsonString.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RecipeParserError.invalidJSONResponse
        }

        let title = json["name"] as? String ?? ""
        let description = json["description"] as? String

        // Servings — can be string like "10" or array like ["10"]
        let servings: Int
        if let yieldArray = json["recipeYield"] as? [String], let first = yieldArray.first {
            servings = Int(first.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 4
        } else if let yieldStr = json["recipeYield"] as? String {
            servings = Int(yieldStr.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 4
        } else {
            servings = 4
        }

        // Times — ISO 8601 duration like "PT30M", "PT2H", "PT1H30M"
        let prepTime = parseISO8601Duration(json["prepTime"] as? String)
        let cookTime = parseISO8601Duration(json["cookTime"] as? String)

        // Ingredients — simple string array
        let ingredients = json["recipeIngredient"] as? [String] ?? []

        // Instructions — can be HowToStep, HowToSection (with nested steps), or plain strings
        let instructions: [String] = extractInstructions(from: json["recipeInstructions"])

        // Tags / category
        let tags: [String]
        if let category = json["recipeCategory"] as? [String] {
            tags = category.map { $0.lowercased() }
        } else if let category = json["recipeCategory"] as? String {
            tags = [category.lowercased()]
        } else {
            tags = []
        }

        let cuisineType: String?
        if let cuisine = json["recipeCuisine"] as? [String] {
            cuisineType = cuisine.first
        } else {
            cuisineType = json["recipeCuisine"] as? String
        }

        return RecipeData(
            title: title,
            description: description,
            servings: servings,
            prepTime: prepTime,
            cookTime: cookTime,
            ingredients: ingredients,
            instructions: instructions,
            tags: tags,
            sourceUrl: sourceUrl,
            cuisineType: cuisineType,
            difficulty: nil
        )
    }

    /// Recursively extract instruction text from schema.org recipeInstructions,
    /// handling HowToStep, HowToSection (with nested itemListElement), and plain strings.
    private func extractInstructions(from value: Any?) -> [String] {
        guard let value else { return [] }

        // Array of items
        if let array = value as? [Any] {
            return array.flatMap { extractInstructions(from: $0) }
        }

        // Dictionary — HowToStep or HowToSection
        if let dict = value as? [String: Any] {
            let type = dict["@type"] as? String ?? ""
            if type == "HowToSection", let items = dict["itemListElement"] {
                return extractInstructions(from: items)
            }
            if let text = dict["text"] as? String, !text.isEmpty {
                return [text]
            }
        }

        // Plain string
        if let str = value as? String, !str.isEmpty {
            return [str]
        }

        return []
    }

    /// Parse ISO 8601 duration (e.g. "PT30M", "PT2H", "PT1H30M") into minutes.
    private func parseISO8601Duration(_ duration: String?) -> Int? {
        guard let duration, duration.hasPrefix("PT") else { return nil }
        let str = String(duration.dropFirst(2)) // drop "PT"

        var totalMinutes = 0
        var numberBuffer = ""

        for char in str {
            if char.isNumber {
                numberBuffer.append(char)
            } else if char == "H", let hours = Int(numberBuffer) {
                totalMinutes += hours * 60
                numberBuffer = ""
            } else if char == "M", let minutes = Int(numberBuffer) {
                totalMinutes += minutes
                numberBuffer = ""
            } else if char == "S" {
                // Ignore seconds
                numberBuffer = ""
            }
        }

        return totalMinutes > 0 ? totalMinutes : nil
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
