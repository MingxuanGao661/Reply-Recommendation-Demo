import Foundation

enum PromptBuilder {

    // MARK: - System Prompts

    private static let systemPromptWithDraft = """
    You are a text messaging assistant that helps users reply to conversations.
    The user has typed a rough draft. Generate 3 polished versions that are ready to send.

    Rules:
    - Tone: {tone} | Length: {length} | Style: {style}
    - Write like a REAL PERSON texting — not like an AI assistant
    - Use lowercase, contractions, and natural abbreviations when fitting
    - Do NOT be overly enthusiastic or add unnecessary exclamation marks
    - Each suggestion MUST directly respond to the last message in the conversation
    - Keep each reply to 1-2 sentences unless length is "long"
    - The 3 suggestions should feel noticeably different from each other:
      "Natural" = how most people would reply
      "Polite" = slightly more considerate/formal
      "Like You" = matches the user's personal style from their draft

    Example:
    Conversation:
      Other: Hey want to grab lunch?
      Me: (draft: "sure")
    Output: {"suggestions": [{"label": "Natural", "text": "Sure, where were you thinking?"}, {"label": "Polite", "text": "Sounds great! Any place in mind?"}, {"label": "Like You", "text": "down, lmk where"}]}

    Return ONLY valid JSON (no markdown, no extra text):
    {"suggestions": [{"label": "Natural", "text": "..."}, {"label": "Polite", "text": "..."}, {"label": "Like You", "text": "..."}]}
    """

    private static let systemPromptNoDraft = """
    You are a text messaging assistant that helps users reply to conversations.
    The user hasn't typed anything yet. Suggest 3 possible replies based on the conversation context.

    Rules:
    - Tone: {tone} | Length: {length} | Style: {style}
    - Write like a REAL PERSON texting — not like an AI assistant
    - Use lowercase, contractions, and natural abbreviations when fitting
    - Do NOT be overly enthusiastic or add unnecessary exclamation marks
    - Focus on the LAST message from the other person — your reply should directly address it
    - Consider the overall mood and topic of the conversation
    - Keep each reply to 1-2 sentences unless length is "long"
    - The 3 suggestions should offer meaningfully different directions:
      "Natural" = the most common/expected reply
      "Polite" = a more considerate/thoughtful version
      "Like You" = a casual, personality-driven reply

    Example:
    Conversation:
      Me: Are you free Saturday?
      Other: Yeah I think so, why?
    Output: {"suggestions": [{"label": "Natural", "text": "Want to check out that new ramen place?"}, {"label": "Polite", "text": "I was hoping we could hang out, maybe grab dinner?"}, {"label": "Like You", "text": "ramen. you in?"}]}

    Return ONLY valid JSON (no markdown, no extra text):
    {"suggestions": [{"label": "Natural", "text": "..."}, {"label": "Polite", "text": "..."}, {"label": "Like You", "text": "..."}]}
    """

    // MARK: - Build System Prompt

    static func buildSystemPrompt(profile: Profile, hasDraft: Bool) -> String {
        let template = hasDraft ? systemPromptWithDraft : systemPromptNoDraft
        return template
            .replacingOccurrences(of: "{tone}", with: profile.tone)
            .replacingOccurrences(of: "{length}", with: profile.length)
            .replacingOccurrences(of: "{style}", with: profile.style)
    }

    // MARK: - Build User Prompt

    static func buildUserPrompt(input: ConversationInput) -> String {
        var lines = ["Conversation:"]
        for msg in input.conversation {
            let tag = msg.speaker == "me" ? "Me" : "Other"
            lines.append("  \(tag): \(msg.text)")
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

    /// Builds a single prompt string using Llama 3.2 chat template
    static func buildLlamaPrompt(input: ConversationInput) -> String {
        let systemPrompt = buildSystemPrompt(
            profile: input.resolvedProfile,
            hasDraft: input.hasDraft
        )
        let userPrompt = buildUserPrompt(input: input)

        return """
        <|begin_of_text|>\
        <|start_header_id|>system<|end_header_id|>

        \(systemPrompt)<|eot_id|>\
        <|start_header_id|>user<|end_header_id|>

        \(userPrompt)<|eot_id|>\
        <|start_header_id|>assistant<|end_header_id|>

        """
    }

    /// Builds a messages array (for OpenAI-compatible APIs / chat completion)
    static func buildMessages(input: ConversationInput) -> [[String: String]] {
        let systemPrompt = buildSystemPrompt(
            profile: input.resolvedProfile,
            hasDraft: input.hasDraft
        )
        let userPrompt = buildUserPrompt(input: input)
        return [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt],
        ]
    }
}
