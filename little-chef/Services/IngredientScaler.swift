//
//  IngredientScaler.swift
//  little-chef
//
//  Rescaling a recipe's ingredient amounts to a different number of servings.
//

import Foundation

/// Scales the amount at the start of an ingredient line.
///
/// Only the leading amount. In "1 (14 oz) can tomatoes" the 1 is how many cans and the 14 is how
/// big each one is, so doubling the recipe means two cans, not one 28-ounce can. A line with no
/// leading amount — "salt to taste", "juice of a lemon" — is left exactly as it is, rather than
/// having a "(scale by 2x)" note appended that piles up every time the servings change again.
///
/// Deterministic, and that matters beyond tidiness: a cooking session scales its working copy
/// and its baseline through this one function, so a serving change on its own cancels out when
/// the two are compared, and only real edits show as unsaved changes.
enum IngredientScaler {

    /// `recipe` with every ingredient amount rescaled to serve `servings`.
    static func scaled(_ recipe: RecipeBase, toServings servings: Int) -> RecipeBase {
        guard servings > 0, recipe.servings > 0, servings != recipe.servings else { return recipe }
        let factor = Double(servings) / Double(recipe.servings)
        var scaled = recipe
        scaled.servings = servings
        scaled.ingredients = recipe.ingredients.map { scale($0, by: factor) }
        return scaled
    }

    /// `line` with its leading amount multiplied by `factor`, or unchanged if it has none.
    static func scale(_ line: String, by factor: Double) -> String {
        guard factor > 0, factor != 1, let amount = leadingAmount(in: line) else { return line }

        let low = format(amount.low * factor)
        let quantity = amount.high.map { "\(low)\(amount.separator)\(format($0 * factor))" } ?? low
        let total = (amount.high ?? amount.low) * factor

        var rest = String(line[amount.range.upperBound...])
        rest = adjustingUnit(in: rest, plural: total > 1.0001)
        return String(line[..<amount.range.lowerBound]) + quantity + rest
    }

    // MARK: - Reading the amount

    private struct Amount {
        let low: Double
        let high: Double?
        /// How the range was written, so "2-3" stays "4-6" and "2 to 3" stays "4 to 6".
        let separator: String
        let range: Range<String.Index>
    }

    private static let unicodeFractions: [Character: Double] = [
        "½": 1.0 / 2, "¼": 1.0 / 4, "¾": 3.0 / 4, "⅓": 1.0 / 3, "⅔": 2.0 / 3,
        "⅛": 1.0 / 8, "⅜": 3.0 / 8, "⅝": 5.0 / 8, "⅞": 7.0 / 8,
    ]

    private static let numberWords: [String: Double] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]

    /// A number as recipes write them, most specific form first: "2 1/2", "1½" or "1 ½", "1/2",
    /// "1.5", "½".
    private static let number = #"(?:\d+\s+\d+/\d+|\d+\s?[½¼¾⅓⅔⅛⅜⅝⅞]|\d+/\d+|\d+(?:\.\d+)?|[½¼¾⅓⅔⅛⅜⅝⅞])"#

    /// An amount at the start of the line, optionally a range. Not followed by "-inch" or
    /// "-pound": "1-inch piece of ginger" is the size of the piece, not a count of anything.
    private static let amountRegex = try? NSRegularExpression(
        pattern: #"^\s*(\#(number))(?:(\s*(?:-|–|to)\s*)(\#(number)))?(?!\s*-\s*[A-Za-z])"#,
        options: [.caseInsensitive]
    )

    private static let wordRegex = try? NSRegularExpression(
        pattern: #"^\s*(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\b"#,
        options: [.caseInsensitive]
    )

    private static func leadingAmount(in line: String) -> Amount? {
        let whole = NSRange(line.startIndex..., in: line)

        if let match = amountRegex?.firstMatch(in: line, range: whole),
           let lowRange = Range(match.range(at: 1), in: line),
           let low = value(of: String(line[lowRange])) {
            var high: Double?
            var separator = ""
            var end = lowRange.upperBound
            if let highRange = Range(match.range(at: 3), in: line),
               let separatorRange = Range(match.range(at: 2), in: line),
               let parsed = value(of: String(line[highRange])) {
                high = parsed
                separator = String(line[separatorRange])
                end = highRange.upperBound
            }
            return Amount(low: low, high: high, separator: separator, range: lowRange.lowerBound..<end)
        }

        if let match = wordRegex?.firstMatch(in: line, range: whole),
           let range = Range(match.range(at: 1), in: line),
           let low = numberWords[line[range].lowercased()] {
            return Amount(low: low, high: nil, separator: "", range: range)
        }
        return nil
    }

    /// The value of one number in any of the forms ``number`` accepts.
    private static func value(of text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let last = text.last, let fraction = unicodeFractions[last] {
            let whole = text.dropLast().trimmingCharacters(in: .whitespaces)
            return whole.isEmpty ? fraction : Double(whole).map { $0 + fraction }
        }
        let parts = text.split(separator: " ")
        if parts.count == 2, let whole = Double(parts[0]), let fraction = simpleFraction(String(parts[1])) {
            return whole + fraction
        }
        return simpleFraction(text) ?? Double(text)
    }

    private static func simpleFraction(_ text: String) -> Double? {
        let parts = text.split(separator: "/")
        guard parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]),
              denominator != 0 else { return nil }
        return numerator / denominator
    }

    // MARK: - Writing it back

    /// The fractions a cook measures in, for snapping a scaled amount to something readable.
    private static let kitchenFractions: [(value: Double, text: String)] = [
        (1.0 / 8, "1/8"), (1.0 / 4, "1/4"), (1.0 / 3, "1/3"), (3.0 / 8, "3/8"), (1.0 / 2, "1/2"),
        (5.0 / 8, "5/8"), (2.0 / 3, "2/3"), (3.0 / 4, "3/4"), (7.0 / 8, "7/8"),
    ]

    /// "1 1/2" rather than "1.5", and whole numbers past ten: nobody weighs out 83.25 grams.
    static func format(_ value: Double) -> String {
        if value >= 10 { return String(Int(value.rounded())) }

        let whole = value.rounded(.down)
        let remainder = value - whole
        if remainder < 0.04 { return String(Int(whole)) }
        if remainder > 0.96 { return String(Int(whole) + 1) }

        if let nearest = kitchenFractions.min(by: { abs($0.value - remainder) < abs($1.value - remainder) }),
           abs(nearest.value - remainder) < 0.04 {
            return whole == 0 ? nearest.text : "\(Int(whole)) \(nearest.text)"
        }
        let decimal = String(format: "%.2f", value)
        return decimal.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    /// Units that read wrong in the wrong number: "2 cup", "1 cups".
    private static let units: [(singular: String, plural: String)] = [
        ("cup", "cups"), ("tablespoon", "tablespoons"), ("teaspoon", "teaspoons"),
        ("clove", "cloves"), ("can", "cans"), ("pound", "pounds"), ("ounce", "ounces"),
        ("slice", "slices"), ("stick", "sticks"), ("sprig", "sprigs"), ("piece", "pieces"),
        ("pinch", "pinches"), ("bunch", "bunches"), ("handful", "handfuls"), ("head", "heads"),
        ("stalk", "stalks"), ("fillet", "fillets"), ("jar", "jars"), ("packet", "packets"),
    ]

    /// Puts the unit right after the amount into the number the new amount needs.
    private static func adjustingUnit(in rest: String, plural: Bool) -> String {
        let leading = rest.prefix { $0 == " " }
        let afterSpace = rest.dropFirst(leading.count)
        let word = afterSpace.prefix { $0.isLetter }
        guard !word.isEmpty else { return rest }
        let lower = word.lowercased()

        for unit in units {
            let replacement: String
            if plural, lower == unit.singular { replacement = unit.plural }
            else if !plural, lower == unit.plural { replacement = unit.singular }
            else { continue }
            let cased = word.first?.isUppercase == true ? replacement.capitalized : replacement
            return String(leading) + cased + afterSpace.dropFirst(word.count)
        }
        return rest
    }
}
