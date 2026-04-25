import Foundation

enum PromptBuilder {

    // MARK: - System prompt core (instructions + merged targets)

    private static let systemPromptWithDraft = """
    You are a text messaging assistant that helps users reply to conversations.
    The user has typed a rough draft. Generate 3 polished versions that are ready to send.

    Rules:
    {style_rules_block}
    - Write like a REAL PERSON texting — not like an AI assistant
    - Use lowercase, contractions, and natural abbreviations when fitting
    - Do NOT be overly enthusiastic or add unnecessary exclamation marks
    - Each suggestion MUST directly respond to {reply_target}
    - Keep each reply to 1-2 sentences unless length is "long"
    - The 3 suggestions should feel noticeably different from each other:
      "Natural" = how most people would reply
      "Polite" = slightly more considerate/formal
      "Like You" = matches the user's personal style from their draft

    Example:
    Conversation:
      Alice: Hey want to grab lunch?
      Me: (draft: "sure")
    Output: {"suggestions": [{"label": "Natural", "text": "Sure, where were you thinking?"}, {"label": "Polite", "text": "Sounds great! Any place in mind?"}, {"label": "Like You", "text": "down, lmk where"}]}

    Return ONLY valid JSON (no markdown, no extra text):
    {"suggestions": [{"label": "Natural", "text": "..."}, {"label": "Polite", "text": "..."}, {"label": "Like You", "text": "..."}]}
    """

    private static let systemPromptNoDraft = """
    You are a text messaging assistant that helps users reply to conversations.
    The user hasn't typed anything yet. Suggest 3 possible replies based on the conversation context.

    Rules:
    {style_rules_block}
    - Write like a REAL PERSON texting — not like an AI assistant
    - Use lowercase, contractions, and natural abbreviations when fitting
    - Do NOT be overly enthusiastic or add unnecessary exclamation marks
    - Focus on {reply_target} — your reply should directly address them
    - Consider the overall mood and topic of the conversation
    - Keep each reply to 1-2 sentences unless length is "long"
    - The 3 suggestions should offer meaningfully different directions:
      "Natural" = the most common/expected reply
      "Polite" = a more considerate/thoughtful version
      "Like You" = a casual, personality-driven reply

    Example:
    Conversation:
      Me: Are you free Saturday?
      Bob: Yeah I think so, why?
    Output: {"suggestions": [{"label": "Natural", "text": "Want to check out that new ramen place?"}, {"label": "Polite", "text": "I was hoping we could hang out, maybe grab dinner?"}, {"label": "Like You", "text": "ramen. you in?"}]}

    Return ONLY valid JSON (no markdown, no extra text):
    {"suggestions": [{"label": "Natural", "text": "..."}, {"label": "Polite", "text": "..."}, {"label": "Like You", "text": "..."}]}
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
        var lines: [String] = [
            "Below is the recent conversation the client included (a bounded window, not necessarily the full chat).",
            "Follow the system instructions and output JSON only.",
            "",
        ]

        if input.isGroupChat && !input.participants.isEmpty {
            let names = input.participants
                .filter { $0.isSelf != true }
                .map { $0.name }
                .joined(separator: ", ")
            lines.append("Group chat with: \(names)")
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
        } else {
            lines.append("\n(no draft yet)")
        }

        lines.append("\nReply with JSON:")
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
