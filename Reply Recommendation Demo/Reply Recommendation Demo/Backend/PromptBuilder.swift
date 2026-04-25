import Foundation

enum PromptBuilder {

    // MARK: - System prompt core (instructions + merged targets)

    /// Short system prompt aligned with `old_python_files/prompt.py` for small LMs (e.g. Llama 3.2 1B).
    /// `{style_rules_block}` + `{reply_target}` preserve merged profile / reply-target behavior.
    private static let systemPromptWithDraft = """
    Complete "Me (typing)" into 3 send-ready messages for {reply_target}.

    {style_rules_block}
    {theme_rules_block}

    Rules:
    - "Me (typing)" is YOUR OWN partial text — each output is a polished version of it. Do NOT reply to it; it is not someone else's message.
    - Keep the core meaning: same yes/no, same times/dates, same intent. Do NOT flip or reverse the draft's answer.
    - The completed text must fit as a reply to {reply_target}. Real texting — short and casual unless length is long.

    Output format: one JSON object only, no markdown. Key "suggestions" = array of exactly 3 objects. Each has "label" ({label_list}) and "text".
    """

    private static let systemPromptNoDraft = """
    Suggest 3 texts Me can send. Answer the OTHER person's last message.

    {style_rules_block}
    {theme_rules_block}

    Rules:
    - Address {reply_target} directly. If they asked a question, answer it; do not only repeat what they said.
    - Obey the Style rules above. Short, casual, real person texting unless length is long. Avoid unnecessary exclamation marks (!).

    Output format: one JSON object only, no markdown. Key "suggestions" = array of exactly 3 objects. Each has "label" ({label_list}) and "text" (Me's real reply for THIS chat).

    Do NOT reuse the same canned line for all three. Do NOT default to "yeah sounds good" or "down" unless they truly fit the thread.
    """

    // MARK: - Style rules (system — user + conversation + effective)

    private static func styleRulesBlock(
        userDefault: Profile?,
        conversation: Profile?,
        effective: Profile
    ) -> String {
        let uTone = userDefault?.tone ?? "not set (no personal preference on this axis)"
        let uLen = userDefault?.length ?? "not set (no personal preference on this axis)"
        let cTone = conversation?.tone ?? "not set (this chat does not override)"
        let cLen = conversation?.length ?? "not set (this chat does not override)"
        return """
    - Style — honor BOTH the user's personal preferences AND this conversation's settings:
      • Personal (user, app-wide): tone: \(uTone) | length: \(uLen)
      • This conversation / thread: tone: \(cTone) | length: \(cLen)
      • Use for THIS reply (per axis: conversation value if set, else personal, else app default warm/short): Tone: \(effective.resolvedTone) | Length: \(effective.resolvedLength)
    """
    }

    // MARK: - Single-tone system prompts

    private static let systemPromptSingleWithDraft = """
    Complete "Me (typing)" into ONE send-ready message in the "{tone_label}" style for {reply_target}.

    {style_rules_block}

    Rules:
    - "Me (typing)" is YOUR OWN partial text — output a polished version of it. Do NOT reply to it; it is not someone else's message.
    - Keep the core meaning: same yes/no, same times/dates, same intent. Do NOT flip or reverse the draft's answer.
    - Style for this message: {tone_description}

    Output: one JSON object only, no markdown. Keys: "label" ("{tone_label}") and "text".
    """

    private static let systemPromptSingleNoDraft = """
    Suggest ONE text Me can send in the "{tone_label}" style. Answer the OTHER person's last message.

    {style_rules_block}
    {theme_rules_block}

    Rules:
    - Address {reply_target} directly. If they asked a question, answer it; do not only repeat what they said.
    - Obey the Style rules above. Short, casual, real person texting unless length is long.
    - Style: {tone_description}

    Output format: one JSON object only, no markdown. Keys: "label" ("{tone_label}") and "text" (Me's real reply for THIS chat).

    Do NOT default to "yeah sounds good" or "down" unless they truly fit the thread.
    """

    // MARK: - Build System Prompt

    static func buildSystemPrompt(
        input: ConversationInput,
        userDefaultProfile: Profile?,
        hasDraft: Bool,
        replyTargetName: String?
    ) -> String {
        let effective = input.effectiveProfile(userDefault: userDefaultProfile)
        let template = hasDraft ? systemPromptWithDraft : systemPromptNoDraft
        let themeSet = input.suggestionThemeSet

        let target: String
        if let name = replyTargetName {
            target = "\(name)'s message"
        } else {
            target = "the last message in the conversation"
        }

        let styleBlock = styleRulesBlock(
            userDefault: userDefaultProfile,
            conversation: input.conversationProfile,
            effective: effective
        )

        return template
            .replacingOccurrences(of: "{style_rules_block}", with: styleBlock)
            .replacingOccurrences(of: "{theme_rules_block}", with: themeRulesBlock(for: themeSet))
            .replacingOccurrences(of: "{label_list}", with: quotedLabelList(for: themeSet))
            .replacingOccurrences(of: "{reply_target}", with: target)
    }

    // MARK: - Build User Prompt

    /// `conversation` is expected to be a **client-chosen window** (e.g. last N messages), not the full thread history.
    static func buildUserPrompt(input: ConversationInput) -> String {
        var lines: [String] = []

        if input.isGroupChat && !input.participants.isEmpty {
            let names = input.participants
                .filter { $0.isSelf != true }
                .map { $0.name }
                .joined(separator: ", ")
            lines.append("Group chat with: \(names)")
            lines.append("")
        }

        lines.append("Conversation:")
        for msg in input.conversation {
            let name = input.displayName(for: msg.speaker)
            lines.append("  \(name): \(msg.text)")
        }

        if input.hasDraft {
            // Embed the draft as the last line of conversation so the model sees it
            // as Me's own in-progress reply, not a separate message to respond to.
            lines.append("  Me (typing): \"\(input.resolvedDraft)\"")
            lines.append("")
            if let targetName = input.replyTargetName {
                lines.append("Complete \"Me (typing)\" into a ready-to-send reply to \(targetName).")
            } else {
                lines.append("Complete \"Me (typing)\" into a ready-to-send reply.")
            }
        } else {
            // Explicitly pin the reply target message so the model focuses on it,
            // not on the full conversation history.
            if let targetMsg = input.replyTargetMessage {
                let targetName = input.replyTargetName ?? "them"
                lines.append("\nReply ONLY to this message from \(targetName): \"\(targetMsg.text)\"")
            } else if let targetName = input.replyTargetName {
                lines.append("\nReplying to: \(targetName)")
            }
            lines.append("(no draft — write a fresh reply)")
        }

        lines.append("\nReply in JSON as instructed.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Single-tone system prompt builder

    static func buildSystemPromptSingle(
        input: ConversationInput,
        userDefaultProfile: Profile?,
        hasDraft: Bool,
        replyTargetName: String?,
        toneLabel: String
    ) -> String {
        let effective = input.effectiveProfile(userDefault: userDefaultProfile)
        let template = hasDraft ? systemPromptSingleWithDraft : systemPromptSingleNoDraft
        let themeSet = input.suggestionThemeSet

        let target: String
        if let name = replyTargetName {
            target = "\(name)'s message"
        } else {
            target = "the last message in the conversation"
        }

        let styleBlock = styleRulesBlock(
            userDefault: userDefaultProfile,
            conversation: input.conversationProfile,
            effective: effective
        )

        return template
            .replacingOccurrences(of: "{style_rules_block}", with: styleBlock)
            .replacingOccurrences(of: "{reply_target}", with: target)
            .replacingOccurrences(of: "{tone_label}", with: toneLabel)
            .replacingOccurrences(of: "{tone_description}", with: themeDescription(for: toneLabel))
            .replacingOccurrences(of: "{theme_rules_block}", with: themeRulesBlock(for: themeSet))
    }

    // MARK: - Build Full Prompt String (for llama.cpp)
    static func buildLlamaPrompt(input: ConversationInput, userDefaultProfile: Profile?) -> String {
        let systemPrompt = buildSystemPrompt(
            input: input,
            userDefaultProfile: userDefaultProfile,
            hasDraft: input.hasDraft,
            replyTargetName: input.replyTargetName
        )
        let userPrompt = buildUserPrompt(input: input)

        return """
        <|begin_of_text|>\
        <|redacted_start_header_id|>system<|redacted_end_header_id|>

        \(systemPrompt)<|eot_id|>\
        <|redacted_start_header_id|>user<|redacted_end_header_id|>

        \(userPrompt)<|eot_id|>\
        <|redacted_start_header_id|>assistant<|redacted_end_header_id|>

        """
    }

    // MARK: - Inline Completion Prompt (Copilot-style)

    /// Lightweight prompt for real-time inline completion.
    ///
    /// Design goals (vs the panel prompts):
    /// - Tiny system prompt — no style rules, no JSON schema
    /// - Only the last conversation turn for context
    /// - Plain-text output so the model doesn't waste tokens on JSON wrapping
    /// - When a draft exists, the assistant turn is **pre-filled** with the draft prefix so
    ///   the model just continues the sentence (true fill-in-the-middle behaviour)
    /// - When no draft, request a short fresh reply
    ///
    /// Caller should use `tokenLimit: 15` and strip everything after `\n` in the output.
    static func buildLlamaPromptInline(input: ConversationInput) -> String {
        let parts = buildLlamaPromptInlineParts(input: input)
        return parts.cacheablePrefix + parts.requestSuffix
    }

    static func buildLlamaPromptInlineParts(input: ConversationInput) -> (cacheablePrefix: String, requestSuffix: String) {
        // Keep inline extremely small: one prior message plus the partial draft.
        var contextLines: [String] = []
        for msg in input.conversation.suffix(1) {
            let name = input.displayName(for: msg.speaker)
            contextLines.append("\(name): \(msg.text)")
        }
        let contextBlock = contextLines.joined(separator: "\n")

        if input.hasDraft {
            let draft = input.resolvedDraft
            let prefix = """
            <|begin_of_text|><|start_header_id|>system<|end_header_id|>

            Continue only a few words.<|eot_id|><|start_header_id|>user<|end_header_id|>

            \(contextBlock)
            Draft:<|eot_id|><|start_header_id|>assistant<|end_header_id|>

            """
            // Pre-fill the assistant turn so llama continues exactly after the draft.
            return (prefix, draft)
        } else {
            let targetLine: String
            if let name = input.replyTargetName {
                targetLine = "Reply to \(name):"
            } else {
                targetLine = "Reply:"
            }
            let prefix = """
            <|begin_of_text|><|start_header_id|>system<|end_header_id|>

            Write one short text reply.<|eot_id|><|start_header_id|>user<|end_header_id|>

            \(contextBlock)

            \(targetLine)<|eot_id|><|start_header_id|>assistant<|end_header_id|>

            """
            return (prefix, "")
        }
    }

    /// Builds a llama.cpp prompt for a single specific tone label.
    /// Used by progressive generation to run one card at a time.
    static func buildLlamaPromptSingle(
        input: ConversationInput,
        userDefaultProfile: Profile?,
        toneLabel: String
    ) -> String {
        let parts = buildLlamaPromptSingleParts(
            input: input,
            userDefaultProfile: userDefaultProfile,
            toneLabel: toneLabel
        )
        return parts.cacheablePrefix + parts.requestSuffix
    }

    /// Builds a single-tone prompt as a stable common prefix plus a small tone-specific suffix.
    /// Progressive generation can keep the prefix KV cache and only swap the suffix per card.
    static func buildLlamaPromptSingleParts(
        input: ConversationInput,
        userDefaultProfile: Profile?,
        toneLabel: String
    ) -> (cacheablePrefix: String, requestSuffix: String) {
        let effective = input.effectiveProfile(userDefault: userDefaultProfile)
        let target: String
        if let name = input.replyTargetName {
            target = "\(name)'s message"
        } else {
            target = "the last message in the conversation"
        }
        let styleBlock = styleRulesBlock(
            userDefault: userDefaultProfile,
            conversation: input.conversationProfile,
            effective: effective
        )
        let commonSystemPrompt: String
        if input.hasDraft {
            commonSystemPrompt = """
            Complete "Me (typing)" into ONE send-ready message for \(target).

            \(styleBlock)

            Rules:
            - "Me (typing)" is YOUR OWN partial text — output a polished version of it. Do NOT reply to it; it is not someone else's message.
            - Keep the core meaning: same yes/no, same times/dates, same intent. Do NOT flip or reverse the draft's answer.
            - Style for this message: see the request below.

            Output: one JSON object only, no markdown. Keys: "label" and "text".
            """
        } else {
            commonSystemPrompt = """
            Suggest ONE text Me can send. Answer the OTHER person's last message.

            \(styleBlock)
            \(themeRulesBlock(for: input.suggestionThemeSet))

            Rules:
            - Address \(target) directly. If they asked a question, answer it; do not only repeat what they said.
            - Obey the Style rules above. Short, casual, real person texting unless length is long.
            - Style: see the request below.

            Output format: one JSON object only, no markdown. Keys: "label" and "text" (Me's real reply for THIS chat).

            Do NOT default to "yeah sounds good" or "down" unless they truly fit the thread.
            """
        }
        let userPrompt = buildUserPrompt(input: input)

        let prefix = """
        <|begin_of_text|>\
        <|start_header_id|>system<|end_header_id|>

        \(commonSystemPrompt)<|eot_id|>\
        <|start_header_id|>user<|end_header_id|>

        \(userPrompt)

        Style request:
        """
        let suffix = """
        - Label: "\(toneLabel)"
        - Style: \(themeDescription(for: toneLabel))
        Output exactly one JSON object with keys "label" and "text"; label must be "\(toneLabel)".<|eot_id|>\
        <|start_header_id|>assistant<|end_header_id|>

        """
        return (prefix, suffix)
    }

    /// Builds a messages array (for OpenAI-compatible APIs / chat completion)
    static func buildMessages(input: ConversationInput, userDefaultProfile: Profile?) -> [[String: String]] {
        let systemPrompt = buildSystemPrompt(
            input: input,
            userDefaultProfile: userDefaultProfile,
            hasDraft: input.hasDraft,
            replyTargetName: input.replyTargetName
        )
        let userPrompt = buildUserPrompt(input: input)
        return [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt],
        ]
    }

    private static func themeRulesBlock(for themeSet: SuggestionThemeSet) -> String {
        switch themeSet {
        case .replyStyles:
            return """
    - Three reply styles — all replying to the LAST message only; each must feel NOTICEABLY different:
      • Direct    = lead with the answer right away; skip warm-ups and filler; shorter is better
      • Friendly  = add one warm or personal touch to YOUR ANSWER (their name, "haha", "for sure"); don't recap the conversation
      • Thoughtful = briefly acknowledge the specific question or situation in the last message, then give your reply
    """
        case .decisionReply:
            return """
    - Three decision stances — all replying to the LAST message; each must give a clearly different answer:
      • Agree       = clear yes / direct acceptance; no hedging
      • Soft Decline = kind no — warm but firm; don't over-explain
      • Delay       = defer without committing — ask for more time or say you'll confirm later
    """
        }
    }

    private static func quotedLabelList(for themeSet: SuggestionThemeSet) -> String {
        themeSet.labels.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    private static func themeDescription(for label: String) -> String {
        switch label.lowercased() {
        case "direct":
            return "lead with the answer, no warm-up or filler — skip pleasantries and get straight to the point; shorter is better"
        case "friendly":
            return "add one warm or personal touch to your answer — use their name, 'haha', or a light affirmation; reply to what they just said, don't recap the conversation"
        case "thoughtful":
            return "briefly acknowledge the specific thing they just asked or mentioned, then give your reply — one step more considerate, but still focused on their last message"
        case "agree":
            return "clear yes / direct acceptance — no hedging, just commit"
        case "soft decline":
            return "kind no — warm but firm; one sentence is enough, don't over-explain"
        case "delay":
            return "defer without committing — ask for more time or say you'll confirm later; don't say yes or no"
        default:
            return "natural, conversational"
        }
    }

    // MARK: - Personal / User LoRA — general only (Llama 3.2 3B tuned)

    /// Shorter system copy for 3B: fewer bullets, explicit output shape (plain text only).
    private static let systemPersonalLoraGeneralNoDraft = """
    You help Me write ONE sendable text in a phone chat (Llama 3.2 3B). Be literal and short.

    {style_rules_block}

    Rules (keep brief — 3B loses long lists):
    1) Output exactly one reply Me can send; match tone/length above.
    2) Sound like real texting, not an essay, list, or coach.
    3) Speak to {reply_target} only; answer a direct question if there is one.
    4) Plain text only: no JSON, no markdown code fences, no Option A/B/C labels.
    5) No roleplay preamble — only Me's line.
    """

    private static let systemPersonalLoraGeneralWithDraft = """
    Polish Me's draft into ONE sendable line (Llama 3.2 3B).

    {style_rules_block}

    Rules (short for 3B):
    1) Same intent as the draft: same yes/no, times, and meaning — never flip the answer.
    2) One line (or one very short paragraph if length is long); natural SMS; match tone/length.
    3) Plain text only — no JSON, no lists, no quotes wrapping the whole reply.
    4) Still a reply to {reply_target}.
    """

    /// User-Lora general threads: same transcript layout as `buildUserPrompt`, but ask for plain text (not JSON).
    static func buildUserPromptPersonalLoraGeneral(input: ConversationInput) -> String {
        var lines: [String] = []

        if input.isGroupChat && !input.participants.isEmpty {
            let names = input.participants
                .filter { $0.isSelf != true }
                .map { $0.name }
                .joined(separator: ", ")
            lines.append("Group chat with: \(names)")
            lines.append("")
        }

        lines.append("Conversation:")
        for msg in input.conversation {
            let name = input.displayName(for: msg.speaker)
            lines.append("  \(name): \(msg.text)")
        }

        if input.hasDraft {
            lines.append("  Me (typing): \"\(input.resolvedDraft)\"")
            lines.append("")
            if let targetName = input.replyTargetName {
                lines.append("Polish Me's typing into one send-ready reply to \(targetName).")
            } else {
                lines.append("Polish Me's typing into one send-ready reply.")
            }
        } else {
            if let targetMsg = input.replyTargetMessage {
                let targetName = input.replyTargetName ?? "them"
                lines.append("\nReply ONLY to this message from \(targetName): \"\(targetMsg.text)\"")
            } else if let targetName = input.replyTargetName {
                lines.append("\nReplying to: \(targetName)")
            }
            lines.append("(no draft — write one reply Me would actually send)")
        }

        lines.append("\nOutput: one plain-text reply only. Stop after that line.")
        return lines.joined(separator: "\n")
    }

    /// Full Llama 3.2 Instruct template for **general + User LoRA**: single plain-text assistant continuation.
    static func buildLlamaPromptPersonalLoraGeneral(input: ConversationInput, userDefaultProfile: Profile?) -> String {
        let effective = input.effectiveProfile(userDefault: userDefaultProfile)
        let styleBlock = styleRulesBlock(
            userDefault: userDefaultProfile,
            conversation: input.conversationProfile,
            effective: effective
        )
        let target: String
        if let name = input.replyTargetName {
            target = "\(name)'s message"
        } else {
            target = "the last message in the conversation"
        }

        let systemCore = input.hasDraft ? systemPersonalLoraGeneralWithDraft : systemPersonalLoraGeneralNoDraft
        let systemPrompt = systemCore
            .replacingOccurrences(of: "{style_rules_block}", with: styleBlock)
            .replacingOccurrences(of: "{reply_target}", with: target)

        let userPrompt = buildUserPromptPersonalLoraGeneral(input: input)

        return """
        <|begin_of_text|>\
        <|start_header_id|>system<|end_header_id|>

        \(systemPrompt)<|eot_id|>\
        <|start_header_id|>user<|end_header_id|>

        \(userPrompt)<|eot_id|>\
        <|start_header_id|>assistant<|end_header_id|>

        """
    }
}
