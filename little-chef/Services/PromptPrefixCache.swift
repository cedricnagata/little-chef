//
//  PromptPrefixCache.swift
//  little-chef
//
//  Keeps the part of a cooking conversation the model has already read, so each question costs
//  only its own tokens. See CLAUDE.md, "Reusing the prompt between questions".
//

import Foundation
import MLX
import MLXLMCommon

/// The model's cache for the settled part of a conversation — everything before the newest
/// question — kept between questions.
///
/// Without it, every question re-read the whole prompt: about 2,600 tokens of instructions,
/// tool definitions and recipe before the first word, many seconds on a phone. With it, a
/// question reads only what arrived since the last one.
///
/// **Why the boundary sits before the newest question.** Bonsai 2's linear-attention layers
/// keep a running state that can't be rewound, so a cache can only ever be extended, never
/// trimmed back to a common prefix. Next turn's prompt always begins with this turn's settled
/// part — the same messages, rendered the same way — but not with this turn's question and
/// reply as generated: the template renders the generation prompt and past replies differently.
/// So the copy kept is the one at the boundary, and the question and answer are read again next
/// turn, as history. That costs a few dozen tokens, not thousands.
///
/// Used only inside `ModelContainer.perform`, which runs one request at a time.
final class PromptPrefixCache: @unchecked Sendable {
    /// The tokens `cache` holds, exactly.
    private var tokens: [Int] = []
    private var cache: [KVCache]?
    /// What the cache belongs to: one cook on one model. A different key starts over.
    private var key: String?

    /// How many tokens the last request found already read, for the log and the Mac check.
    private(set) var lastReusedTokenCount = 0

    func reset() {
        tokens = []
        cache = nil
        key = nil
    }

    /// The working cache for `prompt`, and the tokens still to be fed to it.
    ///
    /// Reuses the kept cache when `prompt` starts with exactly its tokens, reads the rest of the
    /// settled part (`prompt[..<boundary]`), keeps a copy at the boundary for next time, and
    /// returns the copy to generate with alongside `prompt[boundary...]`. A `prompt` the kept
    /// tokens aren't a prefix of — the recipe was edited, history dropped off the front — is read
    /// from the start, as every prompt was before.
    func prepare(
        prompt: [Int], boundary: Int, key: String, model: any LanguageModel, parameters: GenerateParameters
    ) throws -> (cache: [KVCache], suffix: [Int]) {
        let boundary = min(max(boundary, 0), prompt.count - 1)

        var working: [KVCache]
        var start: Int
        if key == self.key, let cache, tokens.count <= boundary, prompt.starts(with: tokens) {
            working = cache.map { $0.copy() }
            start = tokens.count
        } else {
            working = try model.newCache(parameters: parameters)
            start = 0
        }
        lastReusedTokenCount = start

        let step = max(parameters.prefill.stepSize ?? 128, 1)
        while start < boundary {
            let end = min(start + step, boundary)
            let chunk = MLXArray(prompt[start..<end].map(Int32.init))[.newAxis]
            _ = model.nextTokenLogits(LMInput.Text(tokens: chunk), cache: working, state: nil)
            eval(working)
            start = end
        }

        self.cache = working.map { $0.copy() }
        self.tokens = Array(prompt[..<boundary])
        self.key = key
        return (working, Array(prompt[boundary...]))
    }

    /// Where the settled part of a conversation ends: the common prefix of the prompt and the
    /// same conversation rendered with ``placeholderQuestion`` in place of the newest question.
    ///
    /// A placeholder rather than leaving the question out, because Qwen3.5's template refuses a
    /// conversation with no user message ("No user query found"), as the first turn's would be.
    /// The two renders agree up to where the question's text begins.
    static func boundary(prompt: [Int], placeholderPrompt: [Int]) -> Int {
        zip(prompt, placeholderPrompt).prefix { $0 == $1 }.count
    }

    /// Stands in for the newest question in the second render. Any text works that no real
    /// question starts with.
    static let placeholderQuestion = "\u{1}"
}
