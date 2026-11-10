//
//  CookingCommand.swift
//  little-chef
//
//  The things said mid-cook that need no model: timer commands, "how long is left", "repeat
//  that", "what's step 3", "how much salt". Answered in code, at once.
//

import Foundation

/// Answers the commonest cooking commands without asking the model.
///
/// Most of what people say with their hands full is one of a handful of commands, and on a phone
/// each one cost a full model turn: seconds before the first word, for "start the timer". These
/// are matched here against the whole utterance and answered instantly, through the same tools the
/// model would have called, so the wording and the rules (a timer is created stopped) are the same.
///
/// Conservative on purpose. A pattern must match everything that was said, and a command that
/// could mean two things — "start the timer" with two timers waiting, "how much pepper" in a
/// recipe with no pepper — is left to the model. A command answered wrongly is worse than one
/// answered a few seconds later.
@MainActor
enum CookingCommand {
    /// The answer to `text`, or nil to ask the model.
    ///
    /// - Parameters:
    ///   - recipe: the recipe as it stands in the cook, for steps and amounts.
    ///   - lastReply: the assistant's last answer, for "repeat that".
    static func answer(to text: String, recipe: Recipe?, lastReply: String?, tools: CookingTools) -> String? {
        let said = normalized(text)
        guard !said.isEmpty else { return nil }
        let timers = tools.timerManager.getAllTimers()

        if let reply = repeatAnswer(said, lastReply: lastReply) { return reply }
        if let reply = timeLeftAnswer(said, timers: timers) { return reply }
        if let reply = createTimerAnswer(said, tools: tools) { return reply }
        if let reply = timerActionAnswer(said, timers: timers, tools: tools) { return reply }
        if let recipe {
            if let reply = stepAnswer(said, recipe: recipe) { return reply }
            if let reply = amountAnswer(said, recipe: recipe) { return reply }
        }
        return nil
    }

    // MARK: - Repeat

    private static func repeatAnswer(_ said: String, lastReply: String?) -> String? {
        guard matches(said, #"^(?:repeat(?: that| it| yourself| the last thing)?(?: again)?|say (?:that|it) again|what did you (?:just )?say|come again|pardon(?: me)?|one more time)$"#),
              let lastReply, !lastReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return lastReply
    }

    // MARK: - Timers

    private static func timeLeftAnswer(_ said: String, timers: [LocalTimer]) -> String? {
        let patterns = [
            #"^how (?:much time|much longer|long)(?: is| s)?(?: there)?(?: left| remaining| to go)(?: on| for| in)?(?: the| my)?(?: (.+?))?$"#,
            #"^how long (?:until|till|before)(?: the)? (.+?) (?:is done|is ready|goes off|finishes|rings|ends)$"#,
            #"^(?:how are|check)(?: the| my)? (timers?)$"#,
            #"^time check$"#,
        ]
        guard let phrase = firstMatch(said, patterns) else { return nil }
        guard !timers.isEmpty else { return nil }

        let selected: [LocalTimer]
        if let name = timerName(from: phrase) {
            guard let timer = resolve(name, in: timers) else { return nil }
            selected = [timer]
        } else {
            selected = timers
        }
        return selected.map(describe).joined(separator: " ")
    }

    private static func describe(_ timer: LocalTimer) -> String {
        let left = SpokenDuration.text(seconds: timer.remainingSeconds)
        switch timer.status {
        case .running: return "The \(timer.label) timer has \(left) left."
        case .paused: return "The \(timer.label) timer is paused with \(left) left."
        case .new: return "The \(timer.label) timer is set for \(left) and hasn't started."
        case .ended: return "The \(timer.label) timer is done."
        }
    }

    private static func createTimerAnswer(_ said: String, tools: CookingTools) -> String? {
        let verb = #"(?:set|make|create|add|put on|give me|i need)(?: up)?(?: a| an| me a| me an)?"#
        let named = #"(?: (?:for|called|named)(?: the| my)? ([a-z][a-z ]*?))?"#
        // (duration, name) capture order differs by pattern, so each is tried with its own order.
        let forms: [(pattern: String, duration: Int, name: Int)] = [
            ("^\(verb) (.+?) timer\(named)$", 1, 2),
            ("^\(verb) ([a-z][a-z ]*?) timer for (.+)$", 2, 1),
            ("^\(verb) timer(?: (?:called|named) ([a-z][a-z ]*?))? for (.+)$", 2, 1),
            ("^\(verb) timer for (.+?) (?:for|called|named)(?: the| my)? ([a-z][a-z ]*?)$", 1, 2),
            ("^\(verb) timer for(?: the| my)? ([a-z][a-z ]*?) for (.+)$", 2, 1),
            ("^(.+?) timer\(named)$", 1, 2),
        ]
        for form in forms {
            guard let groups = captures(said, form.pattern) else { continue }
            guard let seconds = groups[form.duration].flatMap(duration(from:)), seconds > 0 else { continue }
            let name = groups[form.name].flatMap(timerName(from:)) ?? "timer"
            let minutes = seconds / 60
            return tools.execute(toolName: "create_timer",
                                 arguments: ["name": name, "minutes": minutes, "seconds": seconds % 60]).forUser
        }
        return nil
    }

    private static func timerActionAnswer(_ said: String, timers: [LocalTimer], tools: CookingTools) -> String? {
        let actions: [(pattern: String, tool: String, eligible: (LocalTimer) -> Bool, bareAllowed: Bool)] = [
            (#"^(?:start|resume|unpause)(?: up)?(?: the| my)?(?: (.+?))?$"#, "start_timer",
             { $0.status == .new || $0.status == .paused }, true),
            (#"^(?:stop|pause|hold)(?: the| my)?(?: (.+?))?$"#, "stop_timer", { $0.status == .running }, false),
            (#"^(?:cancel|delete|remove|clear|get rid of)(?: the| my)?(?: (.+?))?$"#, "delete_timer", { _ in true }, false),
        ]
        for action in actions {
            guard let groups = captures(said, action.pattern) else { continue }
            let phrase = groups[1]
            let timer: LocalTimer?
            if let name = phrase.flatMap(timerName(from:)) {
                timer = resolve(name, in: timers)
            } else if phrase == nil || isJustTimer(phrase!) {
                // "start" on its own is what the create reply tells the user to say. "stop" and
                // "cancel" on their own are not taken as timer commands: they as often mean the
                // voice, or the alarm.
                guard action.bareAllowed || phrase != nil else { return nil }
                let eligible = timers.filter(action.eligible)
                timer = eligible.count == 1 ? eligible.first : nil
            } else {
                timer = nil
            }
            guard let timer else { return nil }
            return tools.execute(toolName: action.tool, arguments: ["name": timer.label]).forUser
        }
        return nil
    }

    /// The timer a spoken name refers to: its label, or the one label containing the name ("pasta"
    /// for "pasta water"). Nil when nothing or more than one timer fits. Never a label merely
    /// mentioned in a longer phrase: "stop the chicken from sticking" is not about the chicken timer.
    static func resolve(_ name: String, in timers: [LocalTimer]) -> LocalTimer? {
        if let exact = timers.first(where: { $0.label.caseInsensitiveCompare(name) == .orderedSame }) { return exact }
        let close = timers.filter { $0.label.lowercased().contains(name) }
        return close.count == 1 ? close.first : nil
    }

    /// "the pasta timer" → "pasta"; "timer", "it" or nothing → nil. Long phrases are nil too: a
    /// timer name is a word or two, and "the chicken in the oven" is a sentence about cooking.
    static func timerName(from phrase: String) -> String? {
        var words = phrase.split(separator: " ").map(String.init)
        while let first = words.first, ["the", "my", "a", "an", "that", "this"].contains(first) { words.removeFirst() }
        while let last = words.last, ["timer", "timers", "now", "again", "please"].contains(last) { words.removeLast() }
        guard !words.isEmpty, words.count <= 3, words != ["it"] else { return nil }
        return words.joined(separator: " ")
    }

    private static func isJustTimer(_ phrase: String) -> Bool {
        ["timer", "the timer", "my timer", "it", "the timers", "timers", "it again"].contains(phrase)
    }

    // MARK: - Durations

    private static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20,
        "twenty five": 25, "thirty": 30, "forty": 40, "forty five": 45, "fifty": 50, "sixty": 60, "ninety": 90,
    ]

    /// "5 minutes", "1 and a half hours", "2 minutes 30 seconds", "a minute and a half",
    /// "half an hour", "90 seconds". Nil unless the whole phrase is a duration.
    static func duration(from phrase: String) -> Int? {
        var text = phrase.replacingOccurrences(of: "-", with: " ")
        if ["half an hour", "half hour", "a half hour"].contains(text) { return 1800 }
        let number = #"(\d+(?:\.\d+)?|"# + numberWords.keys.sorted { $0.count > $1.count }.joined(separator: "|") + ")"
        let unit = #"(hours?|hrs?|minutes?|mins?|seconds?|secs?)"#
        let part = try? NSRegularExpression(
            pattern: "^\\s*(?:and\\s+)?\(number)(\\s+and\\s+a\\s+half)?\\s+\(unit)(\\s+and\\s+a\\s+half)?")
        var total = 0.0
        var parts = 0
        while let part, let match = part.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text) {
            func group(_ i: Int) -> String? { Range(match.range(at: i), in: text).map { String(text[$0]) } }
            guard let raw = group(1), let value = Double(raw) ?? numberWords[raw], let unitWord = group(3) else { return nil }
            let half = group(2) != nil || group(4) != nil ? 0.5 : 0
            let scale: Double = unitWord.hasPrefix("h") ? 3600 : unitWord.hasPrefix("m") ? 60 : 1
            total += (value + half) * scale
            parts += 1
            text = String(text[whole.upperBound...])
        }
        guard parts > 0, text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return Int(total.rounded())
    }

    // MARK: - Steps and amounts

    private static let ordinals: [String: Int] = [
        "one": 1, "first": 1, "two": 2, "second": 2, "three": 3, "third": 3, "four": 4, "fourth": 4,
        "five": 5, "fifth": 5, "six": 6, "sixth": 6, "seven": 7, "seventh": 7, "eight": 8, "eighth": 8,
        "nine": 9, "ninth": 9, "ten": 10, "tenth": 10, "eleven": 11, "twelve": 12,
    ]

    private static func stepAnswer(_ said: String, recipe: Recipe) -> String? {
        let steps = recipe.instructions
        guard !steps.isEmpty else { return nil }
        let number: Int
        if let phrase = firstMatch(said, [
            #"^(?:what(?: is| s)?|read(?: me)?|repeat|tell me)? ?step (\w+)(?: again)?$"#,
            #"^(?:what(?: is| s)?|read(?: me)?|repeat|tell me) the (\w+) step(?: again)?$"#,
        ]) {
            if phrase == "last" || phrase == "final" {
                number = steps.count
            } else if let n = Int(phrase) ?? ordinals[phrase] {
                number = n
            } else {
                return nil
            }
        } else {
            return nil
        }
        guard steps.indices.contains(number - 1) else {
            return "The recipe has \(steps.count) \(steps.count == 1 ? "step" : "steps")."
        }
        return "Step \(number): \(steps[number - 1])"
    }

    private static func amountAnswer(_ said: String, recipe: Recipe) -> String? {
        guard let phrase = firstMatch(said, [
            #"^how (?:much|many)(?: of)?(?: the)? ([a-z][a-z ]*?)(?: do i (?:need|use|add|put in)| does (?:it|the recipe) (?:need|take|call for|use)| goes in| is (?:it|that)| in (?:it|this|the recipe))?$"#,
        ]) else { return nil }
        let wanted = IngredientMatcher.normalizedTokens(of: phrase)
        // Short names only: "how much cream should I add to thicken it" is a question for the model.
        guard !wanted.isEmpty, wanted.count <= 3 else { return nil }
        let lines = recipe.ingredients.filter { line in
            guard let parsed = IngredientMatcher.parse(line) else { return false }
            return parsed.names.joined().contains { IngredientMatcher.covers(IngredientMatcher.normalizedTokens(of: $0), wanted) }
        }
        guard !lines.isEmpty, lines.count <= 3 else { return nil }
        return "The recipe calls for \(CookingPrompt.list(lines))."
    }

    // MARK: - Text

    /// Lower case, letters, digits and single spaces; polite openings and closings dropped. What a
    /// speech recogniser writes varies in exactly these ways.
    static func normalized(_ text: String) -> String {
        var said = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: #"[^a-z0-9. ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\.(?!\d)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let openings = ["ok", "okay", "hey", "um", "uh", "so", "alright", "all right", "now", "little chef", "littlechef",
                        "chef", "please", "can you", "could you", "would you", "will you", "can we", "let s", "lets",
                        "go ahead and", "i want to", "i d like to", "and"]
        let closings = ["please", "thanks", "thank you", "now", "for me", "again please"]
        var changed = true
        while changed {
            changed = false
            for opening in openings where said.hasPrefix(opening + " ") {
                said = String(said.dropFirst(opening.count + 1))
                changed = true
            }
            for closing in closings where said.hasSuffix(" " + closing) {
                said = String(said.dropLast(closing.count + 1))
                changed = true
            }
        }
        return said
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        captures(text, pattern) != nil
    }

    /// The first capture group of the first pattern that matches, or "" for a match with none.
    private static func firstMatch(_ text: String, _ patterns: [String]) -> String? {
        for pattern in patterns {
            if let groups = captures(text, pattern) { return groups.count > 1 ? groups[1] ?? "" : "" }
        }
        return nil
    }

    /// Group 0 and every capture group of `pattern` matched against the whole of `text`.
    private static func captures(_ text: String, _ pattern: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (0..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) }
        }
    }
}
