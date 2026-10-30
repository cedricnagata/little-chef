//
//  IngredientMatcher.swift
//  little-chef
//
//  Decides which of a recipe's ingredient lines the kitchen already has.
//
//  Deterministic on purpose. It runs for every recipe every time the list redraws, with or
//  without an AI backend, so it has to be instant and has to give the same answer twice.
//

import Foundation

/// One recipe ingredient line, reduced to what an inventory item could match.
struct ParsedIngredient: Equatable {
    /// The line as the recipe has it, for showing to the user.
    let line: String
    /// What the line needs, one entry per ingredient: "salt and pepper" is two. Each entry lists
    /// the alternatives that would do, so "butter or oil" is one entry of two names.
    let names: [[String]]
    /// "Optional", "for garnish", "to serve": never counted as missing.
    let isOptional: Bool
}

/// What a recipe needs that the kitchen doesn't have.
struct RecipeAvailability: Equatable {
    /// Lines for required ingredients with no match in the inventory, in recipe order.
    let missing: [String]
    /// The same, as names to shop for: "garlic" for "2 cloves garlic, minced". One per missing
    /// ingredient, so a line like "salt and pepper" with only pepper missing gives "pepper".
    let missingNames: [String]
    /// Required ingredient lines, after section headers and always-available items are dropped.
    let requiredCount: Int

    var canMake: Bool { missing.isEmpty }
}

enum IngredientMatcher {

    /// "Missing a few" on the recipes filter.
    static let almostThreshold = 2

    // MARK: - Matching

    /// Which required ingredients of `ingredients` none of `inventory` covers.
    ///
    /// - Parameter inventory: inventory item names as the user typed them, staples included.
    static func availability(of ingredients: [String], inventory: [String]) -> RecipeAvailability {
        let have = inventory.map(normalizedTokens(of:)).filter { !$0.isEmpty }
        var missing: [String] = []
        var missingNames: [String] = []
        var required = 0

        for line in ingredients {
            guard let parsed = parse(line), !parsed.isOptional, !parsed.names.isEmpty else { continue }
            required += 1
            let uncovered = parsed.names.filter { alternatives in
                !alternatives.contains { name in
                    let needed = normalizedTokens(of: name)
                    return have.contains { covers($0, needed) }
                }
            }
            if !uncovered.isEmpty {
                missing.append(line)
                missingNames += uncovered.map { $0.joined(separator: " or ").capitalizedFirst }
            }
        }
        return RecipeAvailability(missing: missing, missingNames: missingNames, requiredCount: required)
    }

    /// Whether an inventory item and a recipe ingredient name are the same thing.
    ///
    /// Either side's words being a subset of the other's: "garlic" covers "garlic cloves", and
    /// "chicken breast" covers a recipe that just says "chicken". Equal-length sets that differ
    /// don't match, which is what keeps "black pepper" from covering "bell pepper".
    static func covers(_ item: Set<String>, _ ingredient: Set<String>) -> Bool {
        guard !item.isEmpty, !ingredient.isEmpty else { return false }
        return item.isSubset(of: ingredient) || ingredient.isSubset(of: item)
    }

    /// Two names for the same item, as far as duplicate detection is concerned.
    static func sameItem(_ a: String, _ b: String) -> Bool {
        let ta = normalizedTokens(of: a)
        return !ta.isEmpty && ta == normalizedTokens(of: b)
    }

    // MARK: - Parsing

    /// The ingredient names in one recipe line, or nil for a line that isn't an ingredient
    /// (a section header such as "For the sauce:", or something always on hand such as water).
    static func parse(_ line: String) -> ParsedIngredient? {
        var text = line.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasSuffix(":") else { return nil }

        let isOptional = optionalMarkers.contains { text.contains($0) }

        // Asides first: "(about 2 cups)", "[optional]".
        text = text.replacingOccurrences(of: "\\([^)]*\\)|\\[[^\\]]*\\]", with: " ", options: .regularExpression)
        // Everything after the first comma is preparation: "garlic, minced", "onion, diced".
        if let comma = text.firstIndex(of: ",") { text = String(text[..<comma]) }
        for marker in trailingMarkers {
            if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
        }

        // An ingredient made of always-available parts ("water", "ice") is dropped, and so is an
        // alternative that is: "water or stock" needs nothing from the inventory.
        var names: [[String]] = []
        for part in text.components(separatedBy: " and ") {
            let alternatives = part.components(separatedBy: " or ")
                .map(stripQuantityAndUnits)
                .filter { !$0.isEmpty }
            guard !alternatives.isEmpty, !alternatives.contains(where: { alwaysAvailable.contains($0) }) else { continue }
            names.append(alternatives)
        }
        guard !names.isEmpty else { return nil }
        return ParsedIngredient(line: line, names: names, isOptional: isOptional)
    }

    /// The words that identify an ingredient, singularized, without amounts or preparation.
    static func normalizedTokens(of name: String) -> Set<String> {
        let words = stripQuantityAndUnits(name.lowercased())
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        return Set(words.map(singular).filter { !$0.isEmpty })
    }

    /// "2 1/2 cups finely chopped fresh parsley" → "parsley".
    static func stripQuantityAndUnits(_ text: String) -> String {
        var words = text
            .replacingOccurrences(of: "[0-9½¼¾⅓⅔⅛⅜⅝⅞./\\-–]+", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }

        words.removeAll { fillerWords.contains($0) || units.contains($0) || descriptors.contains($0) }
        return words.joined(separator: " ")
    }

    /// Cheap English singular: enough for "tomatoes", "berries", "eggs". Leaves short words and
    /// words that only look plural ("asparagus", "hummus", "swiss") alone.
    static func singular(_ word: String) -> String {
        guard word.count > 3, !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("oes") || word.hasSuffix("shes") || word.hasSuffix("ches") { return String(word.dropLast(2)) }
        if word.hasSuffix("s") { return String(word.dropLast()) }
        return word
    }

    // MARK: - Vocabulary

    private static let optionalMarkers = ["optional", "for garnish", "to garnish", "for serving", "to serve"]

    /// Phrases after which the rest of the line is instruction rather than ingredient.
    private static let trailingMarkers = [" to taste", " for garnish", " to garnish", " for serving", " to serve", " optional", " plus more", " divided"]

    /// Never worth checking an inventory for.
    private static let alwaysAvailable: Set<String> = ["water", "ice", "boiling water", "cold water", "warm water", "hot water", "ice water"]

    private static let fillerWords: Set<String> = ["a", "an", "of", "the", "about", "approx", "approximately", "some", "few", "couple", "one", "two", "three", "four", "five", "six", "half", "quarter", "x"]

    private static let units: Set<String> = [
        "cup", "cups", "c", "tablespoon", "tablespoons", "tbsp", "tbs", "tbsps", "teaspoon", "teaspoons", "tsp", "tsps",
        "g", "gram", "grams", "kg", "kilogram", "kilograms", "mg", "ml", "milliliter", "milliliters", "millilitre", "millilitres",
        "l", "liter", "liters", "litre", "litres", "dl", "cl", "oz", "ounce", "ounces", "fl", "lb", "lbs", "pound", "pounds",
        "pint", "pints", "quart", "quarts", "gallon", "gallons", "pinch", "pinches", "dash", "dashes", "splash",
        "clove", "cloves", "can", "cans", "tin", "tins", "jar", "jars", "package", "packages", "pkg", "packet", "packets",
        "bag", "bags", "box", "boxes", "bottle", "bottles", "stick", "sticks", "slice", "slices", "piece", "pieces",
        "bunch", "bunches", "handful", "handfuls", "sprig", "sprigs", "stalk", "stalks", "head", "heads", "sheet", "sheets",
        "fillet", "fillets", "drop", "drops", "knob", "cube", "cubes", "inch", "inches", "cm",
    ]

    /// Preparation and size words that don't change what the ingredient is. Forms that do
    /// ("ground", "smoked") stay, but the subset rule in ``covers(_:_:)`` is lenient by design:
    /// having "cinnamon" still counts for "ground cinnamon". A false "you have it" costs a
    /// substitution; a false "missing" hides a recipe the user could have made.
    private static let descriptors: Set<String> = [
        "fresh", "freshly", "chopped", "finely", "roughly", "coarsely", "minced", "diced", "sliced", "thinly", "thickly",
        "grated", "shredded", "crushed", "peeled", "seeded", "pitted", "trimmed", "rinsed", "drained", "softened",
        "melted", "beaten", "whisked", "sifted", "packed", "heaping", "heaped", "level", "large", "medium", "small",
        "extra", "big", "whole", "halved", "quartered", "cubed", "julienned", "torn", "cooked", "uncooked", "raw",
        "ripe", "room", "temperature", "cold", "warm", "hot", "lukewarm", "good", "quality", "organic", "store", "bought",
        "homemade", "boneless", "skinless", "lightly", "well", "frozen", "thawed", "dried", "toasted", "prepared",
    ]

    // MARK: - Staples

    /// Seeded into a new inventory's staples section. The user can remove any of them.
    static let defaultStaples = [
        "Salt", "Black pepper", "Olive oil", "Vegetable oil", "Butter", "Sugar", "All-purpose flour",
        "Baking soda", "Baking powder", "Garlic", "Onion",
    ]
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
