//
//  ModelReplyText.swift
//  little-chef
//
//  Turning what an on-device model generated into what the user sees and hears.
//

import Foundation

/// Clean-up for a finished on-device reply.
enum ModelReplyText {

    private static let thinkBlock = try? NSRegularExpression(
        pattern: "<think>.*?</think>", options: .dotMatchesLineSeparators
    )
    private static let toolCallBlock = try? NSRegularExpression(
        pattern: "<tool_call>\\s*(.+?)\\s*</tool_call>", options: .dotMatchesLineSeparators
    )

    /// The reply without its reasoning: every `<think>…</think>` block, and everything before a
    /// `</think>` whose opening tag was in the prompt rather than the output.
    static func strippingThinking(_ text: String) -> String {
        var result = text
        if let regex = thinkBlock {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: ""
            )
        }
        if let orphanClose = result.range(of: "</think>") {
            result = String(result[orphanClose.upperBound...])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces each `<tool_call>{"name": …, "arguments": {…}}</tool_call>` the model wrote as
    /// text with what `execute` returns for it, for models that write tool calls instead of
    /// making them. A tag that isn't a readable call is removed.
    ///
    /// Returns "Done!" if nothing but tool calls with empty results was said, so the reply is
    /// never blank.
    static func replacingToolCalls(
        in text: String,
        execute: (_ name: String, _ arguments: [String: Any]) -> String
    ) -> String {
        guard let regex = toolCallBlock else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        // Collected front to back so the tools run in the order the model wrote them, then
        // spliced back to front so earlier ranges stay valid.
        var replacements: [(range: Range<String.Index>, text: String)] = []
        for match in matches {
            guard let fullRange = Range(match.range, in: text),
                  let jsonRange = Range(match.range(at: 1), in: text) else { continue }
            var result = ""
            if let data = String(text[jsonRange]).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String,
               let arguments = json["arguments"] as? [String: Any] {
                result = execute(name, arguments)
            }
            replacements.append((fullRange, result))
        }

        var output = text
        for replacement in replacements.reversed() {
            output.replaceSubrange(replacement.range, with: replacement.text)
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Done!" : trimmed
    }

    /// The part of `reply` that hasn't already been streamed as `streamed`, or "" if the two
    /// diverge — the finished reply replaces the streamed one on screen either way.
    static func unstreamedSuffix(of reply: String, after streamed: String) -> String {
        let shown = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reply.hasPrefix(shown), reply.count > shown.count else { return "" }
        return String(reply.dropFirst(shown.count))
    }
}

/// Keeps a streaming reply's hidden parts hidden while it streams.
///
/// The model's `<think>` reasoning and any `<tool_call>` it writes as text are cleaned out of the
/// finished reply, but the chunks reach the screen — and the speech queue — as they generate.
/// Unfiltered, the chat bubble showed raw tool-call JSON and the hands-free voice read it out.
/// A tag can be split across chunks, so the possible start of one is held back until the next
/// chunk shows what it is.
struct StreamingReplyFilter {
    private static let tags = [(open: "<think>", close: "</think>"), (open: "<tool_call>", close: "</tool_call>")]

    private var pending = ""
    /// The closing tag being waited for while inside a hidden block.
    private var closingTag: String?

    /// Takes the next chunk and returns the part of the reply now safe to show.
    mutating func feed(_ chunk: String) -> String {
        pending += chunk
        var visible = ""

        while true {
            if let close = closingTag {
                if let end = pending.range(of: close) {
                    pending = String(pending[end.upperBound...])
                    closingTag = nil
                    continue
                }
                // Hidden text is dropped as it arrives; only a possible start of the closing
                // tag needs keeping.
                pending = String(pending.suffix(close.count - 1))
                return visible
            }

            if let (range, close) = earliestOpening(in: pending) {
                visible += pending[..<range.lowerBound]
                pending = String(pending[range.upperBound...])
                closingTag = close
                continue
            }

            let held = Self.partialOpeningLength(at: pending)
            visible += pending.dropLast(held)
            pending = String(pending.suffix(held))
            return visible
        }
    }

    /// Whatever was held back, once the reply has finished. Nothing, if it ended inside a hidden
    /// block.
    mutating func finish() -> String {
        defer { pending = ""; closingTag = nil }
        return closingTag == nil ? pending : ""
    }

    private func earliestOpening(in text: String) -> (Range<String.Index>, String)? {
        Self.tags
            .compactMap { tag in text.range(of: tag.open).map { ($0, tag.close) } }
            .min { $0.0.lowerBound < $1.0.lowerBound }
    }

    /// How many trailing characters could be the start of an opening tag — "<", "<thi",
    /// "<tool_c" — and so can't be shown until the next chunk.
    private static func partialOpeningLength(at text: String) -> Int {
        let longest = tags.map(\.open.count).max() ?? 0
        for length in stride(from: min(longest - 1, text.count), through: 1, by: -1) {
            let suffix = text.suffix(length)
            if tags.contains(where: { $0.open.hasPrefix(suffix) }) { return length }
        }
        return 0
    }
}

/// Reads a timer action out of a reply that described one without calling the tool for it.
///
/// Guarded on the word "timer", and that guard must not be loosened. This reads verbs out of
/// ordinary prose, and `deleteTimer` falls back to the only timer when the name doesn't match —
/// so with the recipe tools in play, "Removed 'garlic' from the ingredients" was one sentence
/// away from cancelling the timer on the oven.
enum TimerActionInference {
    struct Action: Equatable {
        let tool: String
        let timerName: String
    }

    /// A quoted name, with the quotes on word boundaries — so the apostrophe in "I've" isn't
    /// taken as the start of one. Straight and curly quotes alike.
    private static let quotedName = try? NSRegularExpression(
        pattern: "(?<![A-Za-z])['\"\u{2018}\u{201C}]([^'\"\u{2018}\u{2019}\u{201C}\u{201D}]+)['\"\u{2019}\u{201D}](?![A-Za-z])"
    )

    static func action(for reply: String) -> Action? {
        let lower = reply.lowercased()
        guard lower.contains("timer") else { return nil }

        // A reply that announces a new timer is describing something already done, and it very
        // often mentions starting in the same breath ("…say start when you're ready").
        // Inferring from that is how a freshly created timer began counting down on its own.
        if lower.contains("creat") || lower.contains("set for") { return nil }

        let name = quotedName?
            .firstMatch(in: reply, range: NSRange(reply.startIndex..., in: reply))
            .flatMap { Range($0.range(at: 1), in: reply) }
            .map { String(reply[$0]) } ?? "timer"

        if lower.contains("stop") || lower.contains("paus") {
            return Action(tool: "stop_timer", timerName: name)
        }
        if lower.contains("delet") || lower.contains("remov") || lower.contains("cancel") {
            return Action(tool: "delete_timer", timerName: name)
        }
        if lower.contains("start") || lower.contains("resum") {
            return Action(tool: "start_timer", timerName: name)
        }
        return nil
    }
}
