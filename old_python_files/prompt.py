from schemas import ConversationInput, Profile

# --- System prompt: with draft (short — for small LMs like 1B) ---
SYSTEM_PROMPT_WITH_DRAFT = """\
You finish the user's draft into a text they can send. You are Me; answer the OTHER person's last message.

MUST follow:
1) FACTS: Keep the draft's meaning. Same times, dates, yes/no, promises, reasons. Do not change to a different time or opposite idea.
2) DRAFT: Start from the draft — complete or lightly polish it into a full sentence or two. Do not ignore the draft.
3) TARGET: Respond to what Other said last. If they asked a question, answer it; do not only repeat or paraphrase what they said.
4) STYLE: {tone} tone, {length} length, {style}. Real texting (short, casual), not robotic. Avoid unnecessary exclamation marks (!).

Three options (different wording):
- Natural = normal
- Polite = softer/kinder
- Like You = closest to how the draft sounds

Output format: one JSON object only, no markdown. Key "suggestions" = array of exactly 3 objects. Each object has "label" (string: Natural, Polite, or Like You) and "text" (string: Me's real reply for THIS chat — must match the draft and Other's last message).

Do NOT paste generic filler. Do NOT use "on my way", "omw", "running late", or "running a few min late" unless the user's draft is clearly about leaving, ETA, or traffic."""

# --- System prompt: no draft (short) ---
SYSTEM_PROMPT_NO_DRAFT = """\
Suggest 3 texts Me can send. Answer the OTHER person's last message.

Rules:
- Style: {tone} tone, {length} length, {style}. Short, casual, real person texting. Avoid unnecessary exclamation marks (!).
- Address what Other just said. If they asked a question, answer it; do not only repeat what they said.
- Natural = normal | Polite = kinder | Like You = casual punchy

Output format: one JSON object only, no markdown. Key "suggestions" = array of exactly 3 objects. Each has "label" (Natural | Polite | Like You) and "text" (Me's real reply for THIS chat).

Do NOT reuse the same canned line for all three. Do NOT default to "yeah sounds good" or "down" unless they truly fit the thread."""


def build_system_prompt(profile: Profile, has_draft: bool = True) -> str:
    template = SYSTEM_PROMPT_WITH_DRAFT if has_draft else SYSTEM_PROMPT_NO_DRAFT
    return template.format(
        tone=profile.tone,
        length=profile.length,
        style=profile.style,
    )


def build_user_prompt(conv_input: ConversationInput) -> str:
    lines = ["Conversation:"]
    for msg in conv_input.conversation:
        tag = "Me" if msg.speaker == "me" else "Other"
        lines.append(f"  {tag}: {msg.text}")

    if conv_input.draft:
        lines.append(f'\nMy draft: "{conv_input.draft}"')
        lines.append(
            "Keep the draft's facts. Expand into a reply to Other's last line. "
            "Each of the 3 texts must fit THIS draft, not a generic late/omw message."
        )
    else:
        lines.append("\n(no draft yet)")

    lines.append("\nReply in JSON as instructed (suggestions array with label + text).")
    return "\n".join(lines)


def build_messages(conv_input: ConversationInput) -> list[dict]:
    """Build the full message list for chat completion APIs."""
    has_draft = bool(conv_input.draft and conv_input.draft.strip())
    return [
        {"role": "system", "content": build_system_prompt(conv_input.profile, has_draft)},
        {"role": "user", "content": build_user_prompt(conv_input)},
    ]
