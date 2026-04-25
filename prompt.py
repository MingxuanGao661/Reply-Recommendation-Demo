from schemas import ConversationInput, Profile

SYSTEM_PROMPT_TEMPLATE = """\
You are a messaging reply assistant.
Given a recent text conversation and the user's rough draft, generate 3 short text message suggestions.

Requirements:
- Tone: {tone}
- Length: {length}
- Style: {style}
- Sound natural and socially appropriate
- Be ready to send
- Keep them concise
- Make the 3 suggestions slightly different in tone

Return ONLY valid JSON (no markdown fences, no extra text) with this exact format:
{{"suggestions": [{{"label": "Natural", "text": "..."}}, {{"label": "Polite", "text": "..."}}, {{"label": "Like You", "text": "..."}}]}}"""


def build_system_prompt(profile: Profile) -> str:
    return SYSTEM_PROMPT_TEMPLATE.format(
        tone=profile.tone,
        length=profile.length,
        style=profile.style,
    )


def build_user_prompt(conv_input: ConversationInput) -> str:
    lines = ["Recent conversation:"]
    for msg in conv_input.conversation:
        tag = "Me" if msg.speaker == "me" else "Other"
        lines.append(f"  {tag}: {msg.text}")
    lines.append(f"\nMy rough draft: \"{conv_input.draft}\"")
    lines.append("\nGenerate 3 reply suggestions as JSON:")
    return "\n".join(lines)


def build_messages(conv_input: ConversationInput) -> list[dict]:
    """Build the full message list for chat completion APIs."""
    return [
        {"role": "system", "content": build_system_prompt(conv_input.profile)},
        {"role": "user", "content": build_user_prompt(conv_input)},
    ]
