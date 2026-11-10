//
//  ReplyTextTests.swift
//  little-chefTests
//
//  What happens to a model's text on its way to the screen and the speaker.
//

import Testing
@testable import little_chef

// MARK: - Sentences for speech

private func sentences(_ chunks: [String]) -> [String] {
    var splitter = SentenceSplitter()
    var out = chunks.flatMap { splitter.append($0) }
    if let rest = splitter.flush() { out.append(rest) }
    return out
}

@Test func splitsOnSentenceEnds() {
    #expect(sentences(["Preheat the oven. Then mix", " the flour! Ready?"]) ==
            ["Preheat the oven.", "Then mix the flour!", "Ready?"])
}

/// A chunk ending in "1." used to be spoken as a sentence of its own, ahead of "5 cups".
@Test func doesNotSplitADecimalAcrossChunks() {
    #expect(sentences(["Use 1.", "5 cups of stock. Stir."]) == ["Use 1.5 cups of stock.", "Stir."])
}

@Test func keepsListNumbersWithTheirStep() {
    #expect(sentences(["1. Preheat the oven. 2. Mix the batter."]) ==
            ["1. Preheat the oven.", "2. Mix the batter."])
}

@Test func splitsOnLineBreaks() {
    #expect(sentences(["Timer 'pasta' created\nAnything else"]) == ["Timer 'pasta' created", "Anything else"])
}

@Test func flushesWhatIsLeft() {
    var splitter = SentenceSplitter()
    #expect(splitter.append("Bake for 20 minutes") == [])
    #expect(splitter.flush() == "Bake for 20 minutes")
    #expect(splitter.flush() == nil)
}

@Test(arguments: [(0, "0 seconds"), (1, "1 second"), (45, "45 seconds"), (60, "1 minute"),
                  (270, "4 minutes and 30 seconds"), (61, "1 minute and 1 second")])
func spellsDurationsOut(seconds: Int, expected: String) {
    #expect(SpokenDuration.text(seconds: seconds) == expected)
}

// MARK: - Finished replies

@Test func stripsThinking() {
    #expect(ModelReplyText.strippingThinking("<think>They want pasta.</think>\nBoil the water.") == "Boil the water.")
    // The opening tag was in the prompt; only the close came back.
    #expect(ModelReplyText.strippingThinking("Pasta, probably.</think> Boil the water.") == "Boil the water.")
    #expect(ModelReplyText.strippingThinking("  Just an answer. ") == "Just an answer.")
}

@Test func runsTextToolCallsInOrder() {
    var calls: [String] = []
    let reply = ModelReplyText.replacingToolCalls(
        in: #"OK. <tool_call>{"name": "create_timer", "arguments": {"name": "pasta"}}</tool_call> And <tool_call>{"name": "start_timer", "arguments": {"name": "rice"}}</tool_call>"#
    ) { name, arguments in
        calls.append("\(name):\(arguments["name"] as? String ?? "")")
        return "[\(name)]"
    }
    #expect(calls == ["create_timer:pasta", "start_timer:rice"])
    #expect(reply == "OK. [create_timer] And [start_timer]")
}

@Test func dropsUnreadableToolCallsAndNeverReturnsBlank() {
    let reply = ModelReplyText.replacingToolCalls(in: "<tool_call>not json</tool_call>") { _, _ in "ran" }
    #expect(reply == "Done!")
    #expect(ModelReplyText.replacingToolCalls(in: "No tools here.") { _, _ in "ran" } == "No tools here.")
}

@Test func findsWhatStillNeedsStreaming() {
    #expect(ModelReplyText.unstreamedSuffix(of: "Sure.\nTimer created.", after: "Sure.") == "\nTimer created.")
    #expect(ModelReplyText.unstreamedSuffix(of: "Sure.", after: "Sure. ") == "")
    #expect(ModelReplyText.unstreamedSuffix(of: "Different", after: "Something else") == "")
}

// MARK: - Streaming filter

private func visible(_ chunks: [String]) -> String {
    var filter = StreamingReplyFilter()
    return chunks.map { filter.feed($0) }.joined() + filter.finish()
}

@Test func hidesThinkingWhileItStreams() {
    #expect(visible(["<think>hmm", " pasta</think>Boil", " it."]) == "Boil it.")
}

/// Tags split across chunks are the normal case, not an edge one.
@Test func hidesTagsSplitAcrossChunks() {
    #expect(visible(["Sure. <to", "ol_call>{\"name\": \"x\"}</tool", "_call> Done."]) == "Sure.  Done.")
    #expect(visible(["<", "think>secret</th", "ink>Shown"]) == "Shown")
}

@Test func releasesAnAngleBracketThatWasNotATag() {
    #expect(visible(["Keep it < 5 minutes. A <", "b"]) == "Keep it < 5 minutes. A <b")
    #expect(visible(["Ends with <"]) == "Ends with <")
}

@Test func dropsAnUnfinishedHiddenBlock() {
    #expect(visible(["Answer. <think>never closed"]) == "Answer. ")
}

// MARK: - Timer inference

@Test func infersTimerActionsFromReplies() {
    #expect(TimerActionInference.action(for: "I've stopped the 'pasta' timer.") ==
            .init(tool: "stop_timer", timerName: "pasta"))
    #expect(TimerActionInference.action(for: "Timer cancelled.") == .init(tool: "delete_timer", timerName: "timer"))
    #expect(TimerActionInference.action(for: "Starting your \"rice\" timer now.") ==
            .init(tool: "start_timer", timerName: "rice"))
}

/// The guard CLAUDE.md says must not be loosened: no "timer", no action.
@Test func ignoresRepliesThatDoNotMentionATimer() {
    #expect(TimerActionInference.action(for: "Removed 'garlic' from the ingredients.") == nil)
    #expect(TimerActionInference.action(for: "Stop stirring once it thickens.") == nil)
}

/// Announcing a new timer is not asking for it to start.
@Test func ignoresRepliesAboutCreatingATimer() {
    #expect(TimerActionInference.action(for: "Timer 'pasta' created — say start when you're ready.") == nil)
    #expect(TimerActionInference.action(for: "Your timer is set for 10 minutes. Start it when ready.") == nil)
}

// MARK: - Spoken text

@Test(arguments: [
    ("Add 1 tbsp of olive oil.", "Add 1 tablespoon of olive oil."),
    ("Use 2 tsp salt and 1/2 tsp pepper.", "Use 2 teaspoons salt and one half teaspoon pepper."),
    ("1 1/2 cups of stock", "1 and a half cups of stock"),
    ("1½ cups", "1 and a half cups"),
    ("¾ cup sugar", "three quarters cup sugar"),
    ("Bake at 350°F for 25 min.", "Bake at 350 degrees Fahrenheit for 25 minutes."),
    ("Heat to 180 °C, about 1 hr.", "Heat to 180 degrees Celsius, about 1 hour."),
    ("Preheat to 425F.", "Preheat to 425 degrees Fahrenheit."),
    ("8 oz cheese and 2 lbs beef", "8 ounces cheese and 2 pounds beef"),
    ("500g flour, 250 ml milk, 1 l water", "500 grams flour, 250 millilitres milk, 1 litre water"),
    ("Add a tbsp of butter, e.g. salted.", "Add a tablespoon of butter, for example salted."),
    ("Rest it 10 mins.", "Rest it 10 minutes."),
])
func expandsWhatSpeechCannotSay(text: String, spoken: String) {
    #expect(SpokenText.forSpeech(text) == spoken)
}

@Test(arguments: [
    "Give it a minute, then taste.",
    "Use a large pan.",
    "Season to taste.",
    "Grate the cheese.",
    "Serves 4.",
])
func leavesOrdinaryWordsAlone(text: String) {
    #expect(SpokenText.forSpeech(text) == text)
}

@Test func dropsAnAbbreviationsStopOnlyMidSentence() {
    #expect(SpokenText.forSpeech("Add 1 tbsp. of oil.") == "Add 1 tablespoon of oil.")
    #expect(SpokenText.forSpeech("Simmer for 5 min. Then serve.") == "Simmer for 5 minutes. Then serve.")
}
