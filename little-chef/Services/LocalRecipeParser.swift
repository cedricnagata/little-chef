//
//  LocalRecipeParser.swift
//  little-chef
//
//  Recipe parser using local LLM, web scraping, and OCR
//

import Foundation
import UIKit
import BigBroKit

@MainActor
class LocalRecipeParser: ObservableObject {
    private let llmService: LLMService
    private let webScraper: WebScraperService
    private let ocrService: OCRService

    @Published var isProcessing = false
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = ""

    convenience init(llmService: LLMService) {
        self.init(llmService: llmService, webScraper: .shared, ocrService: .shared)
    }

    init(llmService: LLMService, webScraper: WebScraperService, ocrService: OCRService) {
        self.llmService = llmService
        self.webScraper = webScraper
        self.ocrService = ocrService
    }

    /// What AI features are available given the active provider and device hardware.
    private var capability: AICapability { llmService.capability }

    // MARK: - Public Methods

    func parseFromURL(_ url: String) async throws -> RecipeParseResponse {
        isProcessing = true
        progress = 0.1
        statusMessage = "Loading webpage..."
        defer {
            isProcessing = false
            progress = 1.0
            statusMessage = ""
            // An import is one-off work. Whatever it had to load stays loaded otherwise, and
            // several gigabytes of it outlive a job that finished a minute ago.
            llmService.releaseModelIfIdle()
        }

        dprint("📖 [PARSER] Parsing URL: \(url)")
        let webContent: String
        do {
            webContent = try await webScraper.scrapeRecipe(from: url)
            dprint("📖 [PARSER] Scraped content length: \(webContent.count) chars")
        } catch {
            dprint("📖 [PARSER] ❌ Scraping failed: \(error.localizedDescription)")
            throw error
        }
        progress = 0.3
        statusMessage = "Extracting recipe data..."

        var recipeData: RecipeData

        if webContent.hasPrefix("Schema.org Recipe JSON:"),
           let parsed = try? parseSchemaOrgRecipe(from: webContent, sourceUrl: url) {
            dprint("📖 [PARSER] ✅ Parsed from schema.org")
            recipeData = parsed

            // Only run LLM cleanup if something is missing, LLM parsing is available, and
            // doing so won't surprise the user with a multi-GB on-device model download —
            // schema.org already gave us a usable recipe, so cleanup is a nice-to-have,
            // not worth silently kicking off a first-time download for.
            let (confidence, _) = evaluateRecipe(recipeData)
            if confidence < 1.0 && capability.llmRecipeParsingEnabled && llmService.isReadyForOpportunisticCleanup {
                dprint("📖 [PARSER] Schema.org incomplete (confidence \(confidence)), running LLM cleanup")
                statusMessage = "Filling in missing details..."
                if let cleaned = try? await cleanupWithLLM(schema: recipeData, sourceUrl: url) {
                    recipeData = cleaned
                }
            }
        } else {
            // No schema.org — would require a full LLM parse. Only allowed when LLM parsing is available.
            guard capability.llmRecipeParsingEnabled else {
                dprint("📖 [PARSER] No schema.org data and LLM parsing unavailable — failing gracefully")
                throw RecipeParserError.aiUnavailable
            }
            dprint("📖 [PARSER] No schema.org data, falling back to LLM")
            statusMessage = "Analyzing recipe with AI..."
            recipeData = try await parseWithLLM(text: webContent, sourceUrl: url, maxTokens: 4096)
        }

        dprint("📖 [PARSER] ✅ Parsed recipe: \(recipeData.title)")
        dprint("📖 [PARSER]   Ingredients: \(recipeData.ingredients.count), Steps: \(recipeData.instructions.count)")
        dprint("📖 [PARSER]   Prep: \(recipeData.prepTime?.description ?? "nil"), Cook: \(recipeData.cookTime?.description ?? "nil")")
        progress = 1.0

        let (confidence, warnings) = evaluateRecipe(recipeData)
        dprint("📖 [PARSER] Confidence: \(confidence), Warnings: \(warnings)")
        return RecipeParseResponse(recipe: recipeData, confidence: confidence, warnings: warnings)
    }

    func parseFromText(_ text: String) async throws -> RecipeParseResponse {
        guard capability.llmRecipeParsingEnabled else { throw RecipeParserError.aiUnavailable }
        isProcessing = true
        progress = 0.2
        statusMessage = "Analyzing recipe with AI..."
        defer { isProcessing = false; progress = 1.0; statusMessage = ""; llmService.releaseModelIfIdle() }

        let recipeData = try await parseWithLLM(text: text, sourceUrl: nil)
        progress = 1.0

        let (confidence, warnings) = evaluateRecipe(recipeData)
        return RecipeParseResponse(recipe: recipeData, confidence: confidence, warnings: warnings)
    }

    func parseFromImages(_ images: [UIImage]) async throws -> RecipeParseResponse {
        guard capability.llmRecipeParsingEnabled else { throw RecipeParserError.aiUnavailable }
        isProcessing = true
        progress = 0.1
        statusMessage = "Reading text from images..."
        defer { isProcessing = false; progress = 1.0; statusMessage = ""; llmService.releaseModelIfIdle() }

        guard !images.isEmpty else { throw RecipeParserError.noImagesProvided }

        let extractedText = try await ocrService.extractText(from: images)
        progress = 0.4

        guard !extractedText.isEmpty else { throw RecipeParserError.noTextExtracted }

        statusMessage = "Analyzing recipe with AI..."
        let recipeData = try await parseWithLLM(text: extractedText, sourceUrl: nil)
        progress = 1.0

        let (confidence, warnings) = evaluateRecipe(recipeData)
        return RecipeParseResponse(recipe: recipeData, confidence: confidence, warnings: warnings)
    }

    // MARK: - Private Methods

    private func parseWithLLM(text: String, sourceUrl: String?, maxTokens: Int = 1024) async throws -> RecipeData {
        let prompt = """
        Build a complete recipe in JSON for the dish in the text below. Return ONLY the JSON object.

        Extraction policy (very important):
        - If a field is present in the text, use the text verbatim — never override or paraphrase what the source says.
        - If a field is missing or unclear in the text, fill it in using your own culinary knowledge of this dish so the recipe is complete and usable.
        - Never output null or empty arrays for ingredients, instructions, or tags. A complete recipe is required.

        Schema:
        - "title": string — the dish name
        - "description": string — one short sentence about the dish
        - "servings": integer — default 4 if not stated and not obvious
        - "prep_time": integer minutes (1 hour = 60). Estimate if not given.
        - "cook_time": integer minutes. Estimate if not given.
        - "ingredients": array of strings, each with a quantity (e.g. "400g spaghetti", "2 cloves garlic, minced")
        - "instructions": array of strings, each a single cooking step in order, plain text only — NO "Step 1:", NO numbering
        - "tags": array of lowercase strings (cuisine, dish type, dietary, etc.)
        - "cuisine_type": string (e.g. "Italian", "Indian"), or null if truly ambiguous
        - "difficulty": "easy" | "medium" | "hard"

        Example output:
        {"title": "Pasta Carbonara", "description": "Classic Roman pasta dish", "servings": 4, "prep_time": 10, "cook_time": 20, "ingredients": ["400g spaghetti", "200g guanciale", "4 egg yolks", "100g pecorino"], "instructions": ["Boil pasta in salted water until al dente.", "Cut guanciale into strips and fry until crispy.", "Mix egg yolks with grated pecorino.", "Toss drained pasta with guanciale, then stir in egg mixture off heat."], "tags": ["italian", "pasta"], "cuisine_type": "Italian", "difficulty": "medium"}

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
            maxTokens: maxTokens,
            // Asked for outright rather than inferred from "this call passes no tools", which
            // is what used to decide it. A Mac constrains the answer to JSON; on device the
            // prompt above is the only thing that can, hence both.
            format: .json
        )

        dprint("📖 [PARSER] LLM raw response (\(response.count) chars):\n\(response.prefix(1000))")

        var recipeData: RecipeData
        do {
            recipeData = try Self.parseRecipeJSON(from: response)
        } catch {
            dprint("📖 [PARSER] ❌ JSON parse failed: \(error)")
            dprint("📖 [PARSER] Full response was:\n\(response)")
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

    static func parseRecipeJSON(from response: String) throws -> RecipeData {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dprint("📖 [PARSER] ❌ JSON parse: empty response")
            throw RecipeParserError.invalidJSONResponse
        }

        // Find JSON in response
        guard let jsonStart = response.firstIndex(of: "{"),
              let jsonEnd = response.lastIndex(of: "}") else {
            dprint("📖 [PARSER] ❌ JSON parse: no '{' or '}' found in response (\(response.count) chars)")
            dprint("📖 [PARSER]   first 200 chars: \(response.prefix(200))")
            throw RecipeParserError.invalidJSONResponse
        }

        var jsonString = String(response[jsonStart...jsonEnd])
        let preStripLen = jsonString.count

        // Fix common LLM JSON issues
        jsonString = jsonString
            .replacingOccurrences(of: ",\\s*}", with: "}", options: .regularExpression)  // trailing commas
            .replacingOccurrences(of: ",\\s*]", with: "]", options: .regularExpression)  // trailing commas in arrays

        if jsonString.count != preStripLen {
            dprint("📖 [PARSER] Fixed trailing-comma issues (\(preStripLen) → \(jsonString.count) chars)")
        }

        guard let jsonData = jsonString.data(using: .utf8) else {
            dprint("📖 [PARSER] ❌ JSON parse: failed to encode JSON string as UTF-8")
            throw RecipeParserError.invalidJSONResponse
        }

        let decoder = JSONDecoder()

        do {
            var recipe = try decoder.decode(RecipeData.self, from: jsonData)
            dprint("📖 [PARSER] ✅ Decoded RecipeData: title='\(recipe.title)', ingr=\(recipe.ingredients.count), steps=\(recipe.instructions.count)")
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
        } catch let DecodingError.keyNotFound(key, ctx) {
            dprint("📖 [PARSER] ❌ JSON missing required key '\(key.stringValue)' at \(ctx.codingPath.map { $0.stringValue }.joined(separator: "."))")
            dprint("📖 [PARSER]   JSON was: \(jsonString.prefix(500))")
            throw RecipeParserError.invalidJSONResponse
        } catch let DecodingError.typeMismatch(type, ctx) {
            dprint("📖 [PARSER] ❌ JSON type mismatch: expected \(type) at \(ctx.codingPath.map { $0.stringValue }.joined(separator: "."))")
            dprint("📖 [PARSER]   JSON was: \(jsonString.prefix(500))")
            throw RecipeParserError.invalidJSONResponse
        } catch let DecodingError.valueNotFound(type, ctx) {
            dprint("📖 [PARSER] ❌ JSON value missing for \(type) at \(ctx.codingPath.map { $0.stringValue }.joined(separator: "."))")
            dprint("📖 [PARSER]   JSON was: \(jsonString.prefix(500))")
            throw RecipeParserError.invalidJSONResponse
        } catch let DecodingError.dataCorrupted(ctx) {
            dprint("📖 [PARSER] ❌ JSON data corrupted at \(ctx.codingPath.map { $0.stringValue }.joined(separator: ".")): \(ctx.debugDescription)")
            dprint("📖 [PARSER]   JSON was: \(jsonString.prefix(500))")
            throw RecipeParserError.invalidJSONResponse
        } catch {
            dprint("📖 [PARSER] ❌ JSON decoding failed: \(error)")
            dprint("📖 [PARSER]   JSON was: \(jsonString.prefix(500))")
            throw RecipeParserError.invalidJSONResponse
        }
    }

    // MARK: - LLM Cleanup Pass

    /// Always run an LLM pass on schema.org data to organize, clean up, and fill any gaps.
    private func cleanupWithLLM(schema: RecipeData, sourceUrl: String?) async throws -> RecipeData {
        let ingredientsList = schema.ingredients.isEmpty ? "NONE FOUND" : schema.ingredients.joined(separator: "\n- ")
        let instructionsList = schema.instructions.isEmpty ? "NONE FOUND" : schema.instructions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

        let prompt = """
        Produce a complete, polished recipe in JSON. Return ONLY the JSON object.

        Source data (already extracted from the page):
        Title: \(schema.title)
        Description: \(schema.description ?? "MISSING")
        Servings: \(schema.servings)
        Prep time: \(schema.prepTime.map { "\($0) minutes" } ?? "MISSING")
        Cook time: \(schema.cookTime.map { "\($0) minutes" } ?? "MISSING")
        Cuisine: \(schema.cuisineType ?? "MISSING")
        Tags: \(schema.tags.isEmpty ? "MISSING" : schema.tags.joined(separator: ", "))

        Ingredients:
        - \(ingredientsList)

        Instructions:
        \(instructionsList)

        Policy (very important):
        - For any field that is present above (not "MISSING" / not "NONE FOUND"), use the source values — clean up formatting only. Do NOT replace or paraphrase the source's choices.
        - For any field marked MISSING or NONE FOUND, fill it in from your own culinary knowledge of this dish so the recipe is complete and usable.
        - Never output null or empty arrays for ingredients, instructions, or tags.

        Schema:
        - "title", "description" (1 sentence), "servings" (int), "prep_time" (int minutes), "cook_time" (int minutes)
        - "ingredients": array of strings with quantities
        - "instructions": array of strings, each a plain cooking step — NO "Step 1:", NO numbering
        - "tags": lowercase string array
        - "cuisine_type": string (or null if truly ambiguous)
        - "difficulty": "easy" | "medium" | "hard"

        Example output:
        {"title": "Recipe Name", "description": "Short description", "servings": 4, "prep_time": 10, "cook_time": 20, "ingredients": ["ingredient 1"], "instructions": ["Do this first."], "tags": ["tag1"], "cuisine_type": "Italian", "difficulty": "medium"}

        Cleanup rules:
        - Strip HTML entities and stray URLs from ingredients/instructions
        - Keep ingredient quantities verbatim from the source
        """

        let response = try await llmService.generateChatCompletion(
            messages: [
                ChatMessage(role: .system, content: "You are a recipe organizer. Clean up and format the recipe data. Output only valid JSON."),
                ChatMessage(role: .user, content: prompt)
            ],
            temperature: 0.2,
            maxTokens: 4096,
            format: .json
        )

        dprint("📖 [PARSER] LLM cleanup response (\(response.count) chars):\n\(response.prefix(500))")

        var cleaned = try Self.parseRecipeJSON(from: response)

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
    case aiUnavailable

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
        case .aiUnavailable:
            return "This recipe needs AI parsing, which isn't available on this device. Try importing from a site with structured recipe data."
        }
    }
}
