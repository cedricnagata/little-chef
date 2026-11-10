//
//  SpeechText.swift
//  little-chef
//
//  Text shaped for being read aloud: replies cut into sentences as they stream, durations
//  spelled out the way a speech model can say them, and the abbreviations recipes are full of
//  expanded before they reach a voice.
//

import Foundation

/// Cuts a streaming reply into sentences, so speech can start a sentence into an answer rather
/// than after all of it.
///
/// A sentence ends at `.`, `!` or `?` followed by whitespace, or at a line break — never at the
/// end of what has arrived so far. A chunk that happens to end in "1." is usually the start of
/// "1.5 cups", and splitting there spoke "Use 1." and then "5 cups" as two sentences. Pieces
/// with no words in them ("2." from a numbered list) are held and joined to what follows, so the
/// speaker isn't handed a bare number to read out on its own.
struct SentenceSplitter {
    private var buffer = ""

    /// Adds `chunk` and returns every sentence it completed, in order.
    mutating func append(_ chunk: String) -> [String] {
        buffer += chunk
        var sentences: [String] = []
        var scanFrom = buffer.startIndex

        while let boundary = Self.nextBoundary(in: buffer, from: scanFrom) {
            let candidate = buffer[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isSpeakable(candidate) {
                sentences.append(candidate)
                buffer = String(buffer[boundary...])
                scanFrom = buffer.startIndex
            } else {
                scanFrom = boundary
            }
        }
        return sentences
    }

    /// Whatever is left once the reply has finished, or nil if that is nothing.
    mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    /// The index just past the next sentence end at or after `start`, or nil if the text so far
    /// doesn't contain one.
    private static func nextBoundary(in text: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\n" { return next }
            if character == "." || character == "!" || character == "?" {
                // Needs to see what follows: "1." at the end of a chunk is not yet a sentence.
                if next < text.endIndex, text[next].isWhitespace { return next }
            }
            index = next
        }
        return nil
    }

    /// Two letters or more: "OK." is a sentence, "2." is a list marker.
    private static func isSpeakable(_ text: String) -> Bool {
        text.filter(\.isLetter).count >= 2
    }
}

/// Durations written out in words, because the text is read aloud by a speech model that says
/// "4m30s" as letters.
enum SpokenDuration {
    /// "4 minutes and 30 seconds", "1 minute", "45 seconds".
    static func text(seconds: Int) -> String {
        let seconds = max(0, seconds)
        let minutes = seconds / 60
        let remainder = seconds % 60
        let minutePart = "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        let secondPart = "\(remainder) \(remainder == 1 ? "second" : "seconds")"
        if minutes > 0 && remainder > 0 { return "\(minutePart) and \(secondPart)" }
        return minutes > 0 ? minutePart : secondPart
    }
}

/// A reply as it should be spoken: the abbreviations, temperatures and fractions recipes are full
/// of, written out in words.
///
/// Speech models read "1 tbsp" as "one tee bee ess pee" and "350°F" as "three fifty degrees eff".
/// The on-screen text keeps the short forms; only what goes to a voice is expanded. Done here
/// rather than by asking the model, which costs prompt on every question and isn't always obeyed.
///
/// Conservative on purpose: a letter that could be a word ("g", "l", "min") is only treated as a
/// unit right after a number, and only common fractions are named.
enum SpokenText {
    static func forSpeech(_ text: String) -> String {
        var text = text
        for rule in rules {
            text = rule.apply(to: text)
        }
        return text
    }

    private struct Rule {
        let regex: NSRegularExpression
        let replace: ([String?]) -> String

        init(_ pattern: String, caseInsensitive: Bool = true, replace: @escaping ([String?]) -> String) {
            regex = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
            self.replace = replace
        }

        func apply(to text: String) -> String {
            let ns = text as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let groups = (0..<match.numberOfRanges).map { index -> String? in
                    let range = match.range(at: index)
                    return range.location == NSNotFound ? nil : ns.substring(with: range)
                }
                result += replace(groups)
                last = match.range.location + match.range.length
            }
            return result + ns.substring(from: last)
        }
    }

    /// A number as recipes write one: digits, a decimal, a fraction, or a mix ("1 1/2", "1½").
    private static let number = #"(\d+(?:[.,]\d+)?(?:\s*[½¼¾⅓⅔⅛]|\s+\d/\d)?|[½¼¾⅓⅔⅛]|\d/\d)"#

    /// An abbreviation's own full stop, dropped only mid-sentence ("1 tbsp. of oil"). At the end of
    /// a sentence the stop is the sentence's, and stays.
    private static let dot = #"(?:\.(?=\s+(?-i:[a-z])))?(?![a-z])"#

    /// Whether a unit after `amount` is singular: "1 teaspoon", "1/2 teaspoon", "2 teaspoons".
    private static func isSingular(_ amount: String) -> Bool {
        let amount = amount.trimmingCharacters(in: .whitespaces)
        if amount == "1" { return true }
        return amount.count <= 3 && (amount.contains("/") || "½¼¾⅓⅔⅛".contains(amount))
    }

    private static func unit(_ singular: String, _ plural: String) -> ([String?]) -> String {
        { groups in
            let amount = groups[1] ?? ""
            return "\(amount) \(isSingular(amount) ? singular : plural)"
        }
    }

    private static let fractions: [String: (alone: String, mixed: String)] = [
        "1/2": ("one half", "a half"), "½": ("one half", "a half"),
        "1/4": ("one quarter", "a quarter"), "¼": ("one quarter", "a quarter"),
        "3/4": ("three quarters", "three quarters"), "¾": ("three quarters", "three quarters"),
        "1/3": ("one third", "a third"), "⅓": ("one third", "a third"),
        "2/3": ("two thirds", "two thirds"), "⅔": ("two thirds", "two thirds"),
        "1/8": ("one eighth", "an eighth"), "⅛": ("one eighth", "an eighth"),
    ]

    private static let rules: [Rule] = [
        // Units after a number. Before the fractions, so "1/2 tsp" can still see its amount.
        Rule(number + #"\s*(?:tsps?|teaspoons?)"# + dot, replace: unit("teaspoon", "teaspoons")),
        Rule(number + #"\s*(?:tbsps?|tbs|tbl|tablespoons?)"# + dot, replace: unit("tablespoon", "tablespoons")),
        Rule(number + #"\s*(?:oz|ounces?)"# + dot, replace: unit("ounce", "ounces")),
        Rule(number + #"\s*(?:lbs?|pounds?)"# + dot, replace: unit("pound", "pounds")),
        Rule(number + #"\s*(?:kg|kilograms?)"# + dot, replace: unit("kilogram", "kilograms")),
        Rule(number + #"\s*(?:g|grams?)"# + dot, replace: unit("gram", "grams")),
        Rule(number + #"\s*(?:ml|millilitres?|milliliters?)"# + dot, replace: unit("millilitre", "millilitres")),
        Rule(number + #"\s*(?:l|litres?|liters?)"# + dot, replace: unit("litre", "litres")),
        Rule(number + #"\s*(?:qts?)"# + dot, replace: unit("quart", "quarts")),
        Rule(number + #"\s*(?:mins?)"# + dot, replace: unit("minute", "minutes")),
        Rule(number + #"\s*(?:hrs?)"# + dot, replace: unit("hour", "hours")),
        Rule(number + #"\s*(?:secs?)"# + dot, replace: unit("second", "seconds")),

        // A unit on its own, where it can't be mistaken for a word: "a tbsp of oil".
        Rule(#"\btsps?\b"# + dot, replace: { _ in "teaspoon" }),
        Rule(#"\btbsps?\b"# + dot, replace: { _ in "tablespoon" }),

        // Temperatures: "350°F", "180 °C", "350F", and a bare "350°".
        Rule(#"(\d+)\s*°\s*F\b|(\d+)F\b"#, caseInsensitive: false, replace: { "\($0[1] ?? $0[2] ?? "") degrees Fahrenheit" }),
        Rule(#"(\d+)\s*°\s*C\b|(\d+)C\b"#, caseInsensitive: false, replace: { "\($0[1] ?? $0[2] ?? "") degrees Celsius" }),
        Rule(#"(\d+)\s*°"#, replace: { "\($0[1] ?? "") degrees" }),

        // Fractions: "1 1/2" and "1½" become "1 and a half", a lone "1/2" "one half".
        Rule(#"(\d+)\s*(1/2|1/4|3/4|1/3|2/3|1/8|½|¼|¾|⅓|⅔|⅛)(?![\d/])"#, replace: { groups in
            "\(groups[1] ?? "") and \(fractions[groups[2] ?? ""]?.mixed ?? (groups[2] ?? ""))"
        }),
        Rule(#"(?<![\d/])(1/2|1/4|3/4|1/3|2/3|1/8|½|¼|¾|⅓|⅔|⅛)(?![\d/])"#, replace: { groups in
            fractions[groups[1] ?? ""]?.alone ?? (groups[1] ?? "")
        }),

        // The Latin ones.
        Rule(#"\be\.g\.,?"#, replace: { _ in "for example" }),
        Rule(#"\bi\.e\.,?"#, replace: { _ in "that is" }),
        Rule(#"\betc\."#, replace: { _ in "and so on" }),
        Rule(#"\bapprox"# + dot, replace: { _ in "approximately" }),
    ]
}
