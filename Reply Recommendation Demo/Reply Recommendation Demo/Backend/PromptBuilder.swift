import Foundation

enum PromptBuilder {

    // MARK: - System prompt core (instructions + merged targets)

    /// Short system prompt aligned with `old_python_files/prompt.py` for small LMs (e.g. Llama 3.2 1B).
    /// `{style_rules_block}` + `{reply_target}` preserve merged profile / reply-target behavior.
    private static let systemPromptWithDraft = """
    You finish the user's draft into a text they can send. You are Me; answer the OTHER person's last message.

    {style_rules_block}

    MUST follow:
    1) FACTS: Keep the draft's meaning. Same times, dates, yes/no, promises, reasons. Do not change to a different time or opposite idea.
    2) DRAFT: Start from the draft — complete or lightly polish it into a full sentence or two. Do not ignore the draft.
    3) TARGET: Respond to {reply_target}. If they asked a question, answer it; do not only repeat or paraphrase what they said.
    4) VOICE: Obey the Style rules above (tone, length). Real texting — short and casual when length is short, not robotic. Avoid unnecessary exclamation marks (!).

    Three options (different wording):
    - Natural = normal
    - Polite = softer/kinder
    - Like You = closest to how the draft sounds

    Output format: one JSON object only, no markdown. Key "suggestions" = array of exactly 3 objects. Each object has "label" (Natural, Polite, or Like You) and "text" (Me's real reply for THIS chat — must match the draft and {reply_target}).

    Do NOT paste generic filler. Do NOT use "on my way", "omw", "running late", or "running a few min late" unless the user's draft is clearly about leaving, ETA, or traffic.
    """

    private static let systemPromptNoDraft = """
    Suggest 3 texts Me can send. Answer the OTHER person's last message.

    {style_rules_block}

    Rules:
    - Address {reply_target} directly. If they asked a question, answer it; do not only repeat what they said.
    - Obey the Style rules above. Short, casual, real person texting unless length is long. Avoid unnecessary exclamation marks (!).
    - Natural = normal | Polite = kinder | Like You = casual punchy

    Output format: one JSON object only, no markdown. Key "suggestions" = array of exactly 3 objects. Each has "label" (Natural | Polite | Like You) and "text" (Me's real reply for THIS chat).

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

    // MARK: - Build System Prompt

    static func buildSystemPrompt(
        input: ConversationInput,
        userDefaultProfile: Profile?,
        hasDraft: Bool,
        replyTargetName: String?
    ) -> String {
        let effective = input.effectiveProfile(userDefault: userDefaultProfile)
        let template = hasDraft ? systemPromptWithDraft : systemPromptNoDraft

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

        if let targetName = input.replyTargetName {
            lines.append("\nReplying to: \(targetName)")
        }

        if input.hasDraft {
            lines.append("\nMy draft: \"\(input.resolvedDraft)\"")
            lines.append(
                "Keep the draft's facts. Expand into a reply to Other's last line. "
                    + "Each of the 3 texts must fit THIS draft, not a generic late/omw message."
            )
        } else {
            lines.append("\n(no draft yet)")
        }

        lines.append("\nReply in JSON as instructed (suggestions array with label + text).")
        return lines.joined(separator: "\n")
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
}
