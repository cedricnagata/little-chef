//
//  LocalRecipeParser.swift
//  little-chef
//
//  Imports a recipe from a URL, pasted text or photos: scraping and OCR to get the text,
//  schema.org or a model to turn it into a recipe. The parsing itself is RecipeExtraction.
//

import Foundation
import UIKit
import BigBroKit

@MainActor
class LocalRecipeParser: ObservableObject {
    private let llmService: LLMService
    private let webScraper: WebScraperService
    private let ocrService: OCRService

    /// What the import is doing right now, shown under the Parse button.
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
        statusMessage = "Loading webpage..."
        defer { statusMessage = "" }

        dprint("📖 [PARSER] Parsing URL: \(url)")
        let page = try await webScraper.scrapeRecipe(from: url)
        statusMessage = "Extracting recipe data..."

        var recipeData: RecipeData

        if case .schemaOrg(let json) = page,
           let parsed = try? RecipeExtraction.fromSchemaOrg(json: json, sourceUrl: url) {
            dprint("📖 [PARSER] ✅ Parsed from schema.org")
            recipeData = parsed

            // Only run LLM cleanup if something is missing, LLM parsing is available, and
            // doing so won't surprise the user with a multi-GB on-device model download —
            // schema.org already gave us a usable recipe, so cleanup is a nice-to-have,
            // not worth silently kicking off a first-time download for.
            let (confidence, _) = RecipeExtraction.evaluate(recipeData)
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
            recipeData = try await parseWithLLM(text: page.text, sourceUrl: url, maxTokens: 4096)
        }

        dprint("📖 [PARSER] ✅ Parsed recipe: \(recipeData.title)")
        dprint("📖 [PARSER]   Ingredients: \(recipeData.ingredients.count), Steps: \(recipeData.instructions.count)")
        dprint("📖 [PARSER]   Prep: \(recipeData.prepTime?.description ?? "nil"), Cook: \(recipeData.cookTime?.description ?? "nil")")

        let (confidence, warnings) = RecipeExtraction.evaluate(recipeData)
        dprint("📖 [PARSER] Confidence: \(confidence), Warnings: \(warnings)")
        return RecipeParseResponse(recipe: recipeData, confidence: confidence, warnings: warnings)
    }

    func parseFromText(_ text: String) async throws -> RecipeParseResponse {
        guard capability.llmRecipeParsingEnabled else { throw RecipeParserError.aiUnavailable }
        statusMessage = "Analyzing recipe with AI..."
        defer { statusMessage = "" }

        let recipeData = try await parseWithLLM(text: text, sourceUrl: nil)

        let (confidence, warnings) = RecipeExtraction.evaluate(recipeData)
        return RecipeParseResponse(recipe: recipeData, confidence: confidence, warnings: warnings)
    }

    func parseFromImages(_ images: [UIImage]) async throws -> RecipeParseResponse {
        guard capability.llmRecipeParsingEnabled else { throw RecipeParserError.aiUnavailable }
        statusMessage = "Reading text from images..."
        defer { statusMessage = "" }

        guard !images.isEmpty else { throw RecipeParserError.noImagesProvided }

        let extractedText = try await ocrService.extractText(from: images)

        guard !extractedText.isEmpty else { throw RecipeParserError.noTextExtracted }

        statusMessage = "Analyzing recipe with AI..."
        let recipeData = try await parseWithLLM(text: extractedText, sourceUrl: nil)

        let (confidence, warnings) = RecipeExtraction.evaluate(recipeData)
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
        \(text.prefix(RecipeExtraction.maxSourceCharacters))
        """

        let response = try await llmService.generateChatCompletion(
            messages: [
                ChatMessage(role: .system, content: "You are a recipe extraction tool. Output only valid JSON. No commentary, no markdown, no numbering of steps.")
            ,
                ChatMessage(role: .user, content: prompt)
            ],
            temperature: 0.2,
            maxTokens: maxTokens,
            responseFormat: .json
        )

        dprint("📖 [PARSER] LLM raw response (\(response.count) chars):\n\(response.prefix(1000))")
        return try RecipeExtraction.fromModelJSON(response).withSourceUrl(sourceUrl)
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
            responseFormat: .json
        )

        dprint("📖 [PARSER] LLM cleanup response (\(response.count) chars):\n\(response.prefix(500))")
        return try RecipeExtraction.fromModelJSON(response).withSourceUrl(sourceUrl)
    }
}
