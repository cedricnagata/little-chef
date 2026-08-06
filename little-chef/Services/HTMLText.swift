//
//  HTMLText.swift
//  little-chef
//
//  Turning scraped web text into something a person — or a speech synthesizer —
//  can read.
//

import Foundation

/// Decoding and cleanup for text lifted out of a web page.
///
/// Recipe sites serve their ingredients and steps as HTML, and the two ways we read them both
/// hand back that HTML's escaping intact: a schema.org JSON-LD block is a JSON *string* whose
/// contents were never un-escaped by anything, and the `innerText` fallback can still carry
/// markup from sites that build their steps out of nested elements. So `Sriracha &#x27;n honey`
/// went into the recipe, into the recipe card, and into the assistant's mouth — where a speech
/// model reads it aloud as a string of digits.
///
/// Decoding is deliberately hand-rolled rather than routed through
/// `NSAttributedString(html:)`: that pulls in WebKit, must run on the main thread, and costs
/// milliseconds per string on a list of forty ingredients.
enum HTMLText {

    /// Everything, in the order a scraped string needs it: markup out, entities decoded,
    /// whitespace normalized.
    ///
    /// Tags are stripped *before* entities are decoded so that a page which escaped its own
    /// example markup (`&lt;b&gt;`) keeps it as literal text rather than having it become a tag
    /// and then vanish.
    static func clean(_ text: String) -> String {
        text
            .strippingHTMLTags()
            .decodingHTMLEntities()
            .normalizingWhitespace()
    }

    /// `clean`, applied to every element, with anything that cleaned down to nothing dropped.
    static func clean(_ lines: [String]) -> [String] {
        lines.map { clean($0) }.filter { !$0.isEmpty }
    }
}

extension String {

    /// Replaces HTML character references with the characters they stand for.
    ///
    /// Handles decimal (`&#39;`), hexadecimal (`&#x27;`) and the named references that actually
    /// turn up in recipe text. Runs twice, because double-encoded text (`&amp;#x27;`) is common
    /// on sites that pass user-submitted recipes through an escaper more than once — one pass
    /// would leave `&#x27;` sitting in the output, which is the exact symptom this fixes.
    func decodingHTMLEntities() -> String {
        var result = self
        for _ in 0..<2 {
            guard result.contains("&") else { break }
            let decoded = result.decodingHTMLEntitiesOnce()
            if decoded == result { break }
            result = decoded
        }
        return result
    }

    private func decodingHTMLEntitiesOnce() -> String {
        var result = ""
        result.reserveCapacity(count)

        var index = startIndex
        while let ampersand = self[index...].firstIndex(of: "&") {
            result.append(contentsOf: self[index..<ampersand])

            // A reference is short. Bounding the search stops a stray "&" in prose from
            // scanning the rest of a 5,000-character page looking for a semicolon.
            let searchEnd = self.index(ampersand, offsetBy: 12, limitedBy: endIndex) ?? endIndex
            guard let semicolon = self[ampersand..<searchEnd].firstIndex(of: ";") else {
                result.append("&")
                index = self.index(after: ampersand)
                continue
            }

            let body = String(self[self.index(after: ampersand)..<semicolon])
            if let replacement = Self.replacement(forEntityBody: body) {
                result.append(replacement)
                index = self.index(after: semicolon)
            } else {
                result.append("&")
                index = self.index(after: ampersand)
            }
        }
        result.append(contentsOf: self[index...])
        return result
    }

    /// The character(s) an entity body (what sits between `&` and `;`) stands for, or nil if it
    /// isn't one we recognize — in which case the `&` is left alone rather than eaten.
    private static func replacement(forEntityBody body: String) -> String? {
        guard !body.isEmpty else { return nil }

        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let scalarValue: UInt32?
            if digits.first == "x" || digits.first == "X" {
                scalarValue = UInt32(digits.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(digits, radix: 10)
            }
            guard let scalarValue, let scalar = Unicode.Scalar(scalarValue) else { return nil }
            return String(Character(scalar))
        }

        return namedEntities[body] ?? namedEntities[body.lowercased()]
    }

    /// The named references recipe pages actually use. Not the full HTML5 table — that is a
    /// couple of thousand entries, and everything outside this list arrives numerically.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "ensp": " ", "emsp": " ", "thinsp": " ", "shy": "",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "sbquo": "\u{201A}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "\u{201E}",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}",
        "bull": "\u{2022}", "middot": "\u{00B7}", "dagger": "\u{2020}",
        "deg": "\u{00B0}", "times": "\u{00D7}", "divide": "\u{00F7}",
        "minus": "\u{2212}", "plusmn": "\u{00B1}", "frac12": "\u{00BD}",
        "frac13": "\u{2153}", "frac14": "\u{00BC}", "frac23": "\u{2154}",
        "frac34": "\u{00BE}", "sup2": "\u{00B2}", "sup3": "\u{00B3}",
        "trade": "\u{2122}", "reg": "\u{00AE}", "copy": "\u{00A9}",
        "eacute": "\u{00E9}", "egrave": "\u{00E8}", "ecirc": "\u{00EA}",
        "agrave": "\u{00E0}", "acirc": "\u{00E2}", "aacute": "\u{00E1}",
        "ccedil": "\u{00E7}", "ntilde": "\u{00F1}", "ograve": "\u{00F2}",
        "oacute": "\u{00F3}", "ocirc": "\u{00F4}", "ouml": "\u{00F6}",
        "uuml": "\u{00FC}", "uacute": "\u{00FA}", "auml": "\u{00E4}",
        "iacute": "\u{00ED}", "icirc": "\u{00EE}", "szlig": "\u{00DF}",
        "Eacute": "\u{00C9}", "Aacute": "\u{00C1}", "Ouml": "\u{00D6}",
        "Uuml": "\u{00DC}", "Auml": "\u{00C4}", "Ccedil": "\u{00C7}",
    ]

    /// Removes HTML tags, turning the ones that mean "line ends here" into newlines first so
    /// that a step list built out of `<li>`s doesn't collapse into one run-on sentence.
    func strippingHTMLTags() -> String {
        guard contains("<") else { return self }
        return
            replacingOccurrences(
                of: "<\\s*(br|/p|/li|/div|/tr|/h[1-6])\\s*/?\\s*>",
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    /// Collapses runs of spaces and blank lines, and trims the ends.
    ///
    /// Stripped markup leaves gaps where the tags were, and non-breaking spaces decoded out of
    /// `&nbsp;` are invisible but not whitespace to `trimmingCharacters`, so they survive as
    /// stray leading indentation on an ingredient unless normalized here.
    func normalizingWhitespace() -> String {
        replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ?\\n[ \\n]*", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
