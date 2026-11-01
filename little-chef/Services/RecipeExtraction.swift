//
//  RecipeExtraction.swift
//  little-chef
//
//  Reading a recipe out of what a web page or a model handed back: schema.org JSON-LD,
//  and the JSON the import prompt asks a model for.
//
//  Lenient by design. Recipe sites fill schema.org in every way the spec allows and several it
//  doesn't, and a small on-device model asked for `"servings": 4` will sometimes write
//  `"servings": "4"`. A strict decoder threw away the whole recipe over that.
//

import Foundation

enum RecipeExtraction {

    /// How much source text an import hands the model. One limit, used by the parser and the
    /// text box alike: the box used to allow 50,000 characters while the prompt quietly kept
    /// the first 5,000, so the end of a long recipe went missing with no sign why.
    static let maxSourceCharacters = 12_000

    // MARK: - schema.org

    /// A schema.org `Recipe` object, as JSON text.
    static func fromSchemaOrg(json text: String, sourceUrl: String?) throws -> RecipeData {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RecipeParserError.invalidJSONResponse
        }
        return fromSchemaOrg(object, sourceUrl: sourceUrl)
    }

    /// Every string goes through `HTMLText.clean`: a JSON-LD block is HTML-escaped source
    /// embedded in a JSON string, and nothing between the page and here un-escapes it.
    static func fromSchemaOrg(_ json: [String: Any], sourceUrl: String?) -> RecipeData {
        RecipeData(
            title: HTMLText.clean(string(json["name"]) ?? ""),
            description: string(json["description"]).map { HTMLText.clean($0) },
            servings: servings(from: json["recipeYield"]) ?? 4,
            prepTime: minutes(from: json["prepTime"]),
            cookTime: minutes(from: json["cookTime"]),
            ingredients: HTMLText.clean(lines(from: json["recipeIngredient"])),
            instructions: HTMLText.clean(instructions(from: json["recipeInstructions"])).map(strippingStepNumber),
            tags: HTMLText.clean(lines(from: json["recipeCategory"])).map { $0.lowercased() },
            sourceUrl: sourceUrl,
            cuisineType: lines(from: json["recipeCuisine"]).first.map { HTMLText.clean($0) },
            difficulty: nil
        )
    }

    /// The steps in `recipeInstructions`, which can be plain strings, `HowToStep`s,
    /// `HowToSection`s of steps, or one string holding the whole method.
    static func instructions(from value: Any?) -> [String] {
        switch value {
        case let array as [Any]:
            return array.flatMap { instructions(from: $0) }
        case let object as [String: Any]:
            if let items = object["itemListElement"] {
                return instructions(from: items)
            }
            return (string(object["text"]) ?? string(object["name"])).map { [$0] } ?? []
        case let text as String:
            // A whole method in one string is a line per step far more often than one step.
            return text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        default:
            return []
        }
    }

    // MARK: - Model output

    /// The recipe in a model's answer to the import prompt.
    ///
    /// Takes the outermost `{…}`, tolerates trailing commas, and reads each field in whatever
    /// shape it arrived: numbers as strings, a list as one string, a missing list as empty.
    static func fromModelJSON(_ response: String) throws -> RecipeData {
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), start < end else {
            throw RecipeParserError.invalidJSONResponse
        }
        // Brackets escaped: an unescaped `}` is a syntax error to some ICU builds, and a failed
        // pattern makes `replacingOccurrences` return an empty string rather than the input.
        let text = String(response[start...end])
            .replacingOccurrences(of: ",\\s*\\}", with: "}", options: .regularExpression)
            .replacingOccurrences(of: ",\\s*\\]", with: "]", options: .regularExpression)
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RecipeParserError.invalidJSONResponse
        }

        func field(_ keys: String...) -> Any? { keys.lazy.compactMap { json[$0] }.first }

        let recipe = RecipeData(
            title: HTMLText.clean(string(field("title", "name")) ?? ""),
            description: string(field("description")).map { HTMLText.clean($0) },
            servings: servings(from: field("servings", "yield")) ?? 4,
            prepTime: minutes(from: field("prep_time", "prepTime")),
            cookTime: minutes(from: field("cook_time", "cookTime")),
            ingredients: HTMLText.clean(lines(from: field("ingredients"))),
            // Plain steps only. Models number them however hard the prompt asks them not to.
            instructions: HTMLText.clean(lines(from: field("instructions", "steps"))).map(strippingStepNumber),
            tags: HTMLText.clean(lines(from: field("tags"))).map { $0.lowercased() },
            sourceUrl: string(field("source_url", "sourceUrl")),
            cuisineType: string(field("cuisine_type", "cuisineType", "cuisine")).map { HTMLText.clean($0) },
            difficulty: string(field("difficulty"))?.lowercased()
        )
        guard !recipe.title.isEmpty || !recipe.ingredients.isEmpty else {
            throw RecipeParserError.invalidJSONResponse
        }
        return recipe
    }

    // MARK: - Fields

    /// Servings from a yield: `4`, `"4"`, `"4-6 servings"` (4), `"Makes 12 cookies"` (12),
    /// or a list of any of those.
    ///
    /// The first number, not every digit in the string: joining them read "4-6 servings" as 46.
    static func servings(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            let servings = number.intValue
            return servings > 0 ? servings : nil
        case let text as String:
            guard let range = text.range(of: "\\d+", options: .regularExpression),
                  let servings = Int(text[range]), servings > 0 else { return nil }
            return servings
        case let array as [Any]:
            return array.lazy.compactMap { servings(from: $0) }.first
        default:
            return nil
        }
    }

    /// Minutes from an ISO 8601 duration ("PT1H30M", "P1DT2H"), plain prose ("1 hour 30
    /// minutes", "45 min"), or a bare number.
    static func minutes(from value: Any?) -> Int? {
        let total: Double?
        switch value {
        case let number as NSNumber:
            total = number.doubleValue
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.uppercased().hasPrefix("P") {
                total = isoMinutes(trimmed.uppercased())
            } else {
                total = proseMinutes(trimmed.lowercased())
            }
        default:
            total = nil
        }
        guard let total, total >= 1 else { return nil }
        return Int(total.rounded())
    }

    private static func isoMinutes(_ text: String) -> Double? {
        var minutes = 0.0
        var number = ""
        var inTime = false
        for character in text.dropFirst() {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            if character == "T" { inTime = true; continue }
            let value = Double(number) ?? 0
            number = ""
            switch (character, inTime) {
            case ("W", false): minutes += value * 7 * 24 * 60
            case ("D", false): minutes += value * 24 * 60
            case ("H", true): minutes += value * 60
            case ("M", true): minutes += value
            case ("S", true): minutes += value / 60
            default: break
            }
        }
        return minutes > 0 ? minutes : nil
    }

    private static func proseMinutes(_ text: String) -> Double? {
        if let bare = Double(text) { return bare }
        func amount(_ pattern: String) -> Double {
            guard let range = text.range(of: pattern, options: .regularExpression) else { return 0 }
            let digits = text[range].prefix { $0.isNumber || $0 == "." }
            return Double(digits) ?? 0
        }
        let total = amount("\\d+(\\.\\d+)?\\s*(h|hr|hrs|hour|hours)\\b") * 60
            + amount("\\d+(\\.\\d+)?\\s*(m|min|mins|minute|minutes)\\b")
        return total > 0 ? total : nil
    }

    /// A list field as lines: an array of strings (or numbers), or one string with a line each.
    static func lines(from value: Any?) -> [String] {
        switch value {
        case let array as [Any]:
            return array.compactMap { string($0) }
        case let text as String:
            return text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        default:
            return []
        }
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            return array.lazy.compactMap { string($0) }.first
        default:
            return nil
        }
    }

    /// "1. Preheat the oven" → "Preheat the oven", and the "Step 1:" and "1)" forms too.
    static func strippingStepNumber(_ step: String) -> String {
        step.replacingOccurrences(
            of: "^\\s*(?:step\\s*)?\\d+\\s*[.:)\\-]\\s*",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    // MARK: - Confidence

    /// How complete a parsed recipe looks, and what is missing from it.
    static func evaluate(_ recipe: RecipeData) -> (confidence: Double, warnings: [String]) {
        var confidence = 1.0
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

        return (max(0, min(1, confidence)), warnings)
    }
}

extension RecipeData {
    /// The same recipe credited to `url`.
    func withSourceUrl(_ url: String?) -> RecipeData {
        guard let url else { return self }
        return RecipeData(
            title: title, description: description, servings: servings, prepTime: prepTime,
            cookTime: cookTime, ingredients: ingredients, instructions: instructions, tags: tags,
            sourceUrl: url, cuisineType: cuisineType, difficulty: difficulty
        )
    }
}

enum RecipeParserError: LocalizedError {
    case noImagesProvided
    case noTextExtracted
    case invalidJSONResponse
    case aiUnavailable

    var errorDescription: String? {
        switch self {
        case .noImagesProvided:
            return "No images provided for parsing"
        case .noTextExtracted:
            return "Could not read text from images. Ensure images contain readable text."
        case .invalidJSONResponse:
            return "Failed to parse recipe. Please try again."
        case .aiUnavailable:
            return "This recipe needs AI parsing, which isn't available on this device. Try importing from a site with structured recipe data."
        }
    }
}
