//
//  SpeechText.swift
//  little-chef
//
//  Text shaped for being read aloud: replies cut into sentences as they stream, and durations
//  spelled out the way a speech model can say them.
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
