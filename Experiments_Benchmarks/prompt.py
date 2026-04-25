"""Prompt strings aligned with `PromptBuilder.swift` / `Models.swift` (iOS app)."""
from __future__ import annotations

from textwrap import dedent
from typing import List, Optional

from schemas import ConversationInput, Profile, SuggestionThemeSet


# --- System prompt core (same literals as Swift `systemPromptWithDraft` / `systemPromptNoDraft`) ---

SYSTEM_PROMPT_WITH_DRAFT = dedent(
    """
    Complete "Me (typing)" into 3 send-ready messages for {reply_target}.

    {style_rules_block}
    {theme_rules_block}

    Rules:
    - "Me (typing)" is YOUR OWN partial text — each output is a polished version of it. Do NOT reply to it; it is not someone else's message.
    - Keep the core meaning: same yes/no, same times/dates, same intent. Do NOT flip or reverse the draft's answer.
    - The completed text must fit as a reply to {reply_target}. Real texting — short and casual unless length is long.

    Output format: one JSON object only, no markdown. Key "suggestions" = array of exactly 3 objects. Each has "label" ({label_list}) and "text".
    """
).strip()

SYSTEM_PROMPT_NO_DRAFT = dedent(
    """
    Suggest 3 texts Me can send. Answer the OTHER person's last message.

    {style_rules_block}
    {theme_rules_block}

    Rules:
    - Address {reply_target} directly. If they asked a question, answer it; do not only repeat what they said.
    - Obey the Style rules above. Short, casual, real person texting unless length is long. Avoid unnecessary exclamation marks (!).

    Output format: one JSON object only, no markdown. Key "suggestions" = array of exactly 3 objects. Each has "label" ({label_list}) and "text" (Me's real reply for THIS chat).

    Do NOT reuse the same canned line for all three. Do NOT default to "yeah sounds good" or "down" unless they truly fit the thread.
    """
).strip()

SYSTEM_PROMPT_SINGLE_WITH_DRAFT = dedent(
    """
    Complete "Me (typing)" into ONE send-ready message in the "{tone_label}" style for {reply_target}.

    {style_rules_block}

    Rules:
    - "Me (typing)" is YOUR OWN partial text — output a polished version of it. Do NOT reply to it; it is not someone else's message.
    - Keep the core meaning: same yes/no, same times/dates, same intent. Do NOT flip or reverse the draft's answer.
    - Style for this message: {tone_description}

    Output: one JSON object only, no markdown. Keys: "label" ("{tone_label}") and "text".
    """
).strip()

SYSTEM_PROMPT_SINGLE_NO_DRAFT = dedent(
    """
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
).strip()

THEME_REPLY_STYLES = dedent(
    """
    - Three reply styles — all replying to the LAST message only; each must feel NOTICEABLY different:
      • Direct    = lead with the answer right away; skip warm-ups and filler; shorter is better
      • Friendly  = add one warm or personal touch to YOUR ANSWER (their name, "haha", "for sure"); don't recap the conversation
      • Thoughtful = briefly acknowledge the specific question or situation in the last message, then give your reply
    """
).strip()

THEME_DECISION = dedent(
    """
    - Three decision stances — all replying to the LAST message; each must give a clearly different answer:
      • Agree       = clear yes / direct acceptance; no hedging
      • Soft Decline = kind no — warm but firm; don't over-explain
      • Delay       = defer without committing — ask for more time or say you'll confirm later
    """
).strip()


def style_rules_block(
    user_default: Optional[Profile],
    conversation_profile: Optional[Profile],
    effective_tone: str,
    effective_length: str,
) -> str:
    u = user_default or Profile()
    c = conversation_profile
    u_tone = u.tone if u.tone is not None else "not set (no personal preference on this axis)"
    u_len = u.length if u.length is not None else "not set (no personal preference on this axis)"
    c_tone = (
        c.tone
        if c and c.tone is not None
        else "not set (this chat does not override)"
    )
    c_len = (
        c.length
        if c and c.length is not None
        else "not set (this chat does not override)"
    )
    return dedent(
        f"""
    - Style — honor BOTH the user's personal preferences AND this conversation's settings:
      • Personal (user, app-wide): tone: {u_tone} | length: {u_len}
      • This conversation / thread: tone: {c_tone} | length: {c_len}
      • Use for THIS reply (per axis: conversation value if set, else personal, else app default warm/short): Tone: {effective_tone} | Length: {effective_length}
    """
    ).strip()


def theme_rules_block(theme_set: SuggestionThemeSet) -> str:
    return THEME_DECISION if theme_set is SuggestionThemeSet.DECISION_REPLY else THEME_REPLY_STYLES


def quoted_label_list(theme_set: SuggestionThemeSet) -> str:
    return ", ".join(f'"{x}"' for x in theme_set.labels)


def theme_description(label: str) -> str:
    key = label.lower()
    if key == "direct":
        return (
            "lead with the answer, no warm-up or filler — skip pleasantries and get straight to the point; "
            "shorter is better"
        )
    if key == "friendly":
        return (
            "add one warm or personal touch to your answer — use their name, 'haha', or a light affirmation; "
            "reply to what they just said, don't recap the conversation"
        )
    if key == "thoughtful":
        return (
            "briefly acknowledge the specific thing they just asked or mentioned, then give your reply — "
            "one step more considerate, but still focused on their last message"
        )
    if key == "agree":
        return "clear yes / direct acceptance — no hedging, just commit"
    if key == "soft decline":
        return "kind no — warm but firm; one sentence is enough, don't over-explain"
    if key == "delay":
        return "defer without committing — ask for more time or say you'll confirm later; don't say yes or no"
    return "natural, conversational"


def build_system_prompt(
    conv_input: ConversationInput,
    user_default_profile: Optional[Profile] = None,
    *,
    has_draft: Optional[bool] = None,
    reply_target_name: Optional[str] = None,
) -> str:
    """Mirrors `PromptBuilder.buildSystemPrompt` in Swift."""
    user_default = (
        user_default_profile if user_default_profile is not None else conv_input.profile
    )
    hd = conv_input.has_draft if has_draft is None else has_draft
    effective = conv_input.effective_profile(user_default=user_default)
    eff_tone, eff_len = effective.resolved_tone, effective.resolved_length
    style_block = style_rules_block(
        user_default=user_default,
        conversation_profile=conv_input.conversation_profile,
        effective_tone=eff_tone,
        effective_length=eff_len,
    )
    theme_set = conv_input.suggestion_theme_set()
    template = SYSTEM_PROMPT_WITH_DRAFT if hd else SYSTEM_PROMPT_NO_DRAFT

    name = (
        reply_target_name
        if reply_target_name is not None
        else conv_input.reply_target_name
    )
    if name:
        target = f"{name}'s message"
    else:
        target = "the last message in the conversation"

    return (
        template.replace("{style_rules_block}", style_block)
        .replace("{theme_rules_block}", theme_rules_block(theme_set))
        .replace("{label_list}", quoted_label_list(theme_set))
        .replace("{reply_target}", target)
    )


def build_user_prompt(conv_input: ConversationInput) -> str:
    """Mirrors `PromptBuilder.buildUserPrompt` in Swift."""
    lines: List[str] = []

    if conv_input.is_group_chat and conv_input.participants:
        names = [
            p.name
            for p in conv_input.participants
            if not p.is_self
        ]
        lines.append(f"Group chat with: {', '.join(names)}")
        lines.append("")

    lines.append("Conversation:")
    for msg in conv_input.conversation:
        name = conv_input.display_name(msg.speaker)
        lines.append(f"  {name}: {msg.text}")

    if conv_input.has_draft:
        lines.append(f'  Me (typing): "{conv_input.resolved_draft}"')
        lines.append("")
        target_name = conv_input.reply_target_name
        if target_name:
            lines.append(
                f'Complete "Me (typing)" into a ready-to-send reply to {target_name}.'
            )
        else:
            lines.append('Complete "Me (typing)" into a ready-to-send reply.')
    else:
        tgt_msg = conv_input.reply_target_message
        if tgt_msg:
            target_name = conv_input.reply_target_name or "them"
            lines.append(f'\nReply ONLY to this message from {target_name}: "{tgt_msg.text}"')
        elif conv_input.reply_target_name:
            lines.append(f"\nReplying to: {conv_input.reply_target_name}")
        lines.append("(no draft — write a fresh reply)")

    lines.append("\nReply in JSON as instructed.")
    return "\n".join(lines)


def build_system_prompt_single(
    conv_input: ConversationInput,
    tone_label: str,
    user_default_profile: Optional[Profile] = None,
    *,
    has_draft: Optional[bool] = None,
    reply_target_name: Optional[str] = None,
) -> str:
    """Mirrors `PromptBuilder.buildSystemPromptSingle` in Swift."""
    user_default = (
        user_default_profile if user_default_profile is not None else conv_input.profile
    )
    hd = conv_input.has_draft if has_draft is None else has_draft
    effective = conv_input.effective_profile(user_default=user_default)
    eff_tone, eff_len = effective.resolved_tone, effective.resolved_length
    style_block = style_rules_block(
        user_default=user_default,
        conversation_profile=conv_input.conversation_profile,
        effective_tone=eff_tone,
        effective_length=eff_len,
    )
    theme_set = conv_input.suggestion_theme_set()
    template = SYSTEM_PROMPT_SINGLE_WITH_DRAFT if hd else SYSTEM_PROMPT_SINGLE_NO_DRAFT

    name = (
        reply_target_name
        if reply_target_name is not None
        else conv_input.reply_target_name
    )
    if name:
        target = f"{name}'s message"
    else:
        target = "the last message in the conversation"

    return (
        template.replace("{style_rules_block}", style_block)
        .replace("{reply_target}", target)
        .replace("{tone_label}", tone_label)
        .replace("{tone_description}", theme_description(tone_label))
        .replace("{theme_rules_block}", theme_rules_block(theme_set))
    )


def build_messages(
    conv_input: ConversationInput,
    user_default_profile: Optional[Profile] = None,
) -> list[dict]:
    """Build the full message list for chat completion APIs (same roles as `PromptBuilder.buildMessages`)."""
    ud = user_default_profile if user_default_profile is not None else conv_input.profile
    return [
        {"role": "system", "content": build_system_prompt(conv_input, user_default_profile=ud)},
        {"role": "user", "content": build_user_prompt(conv_input)},
    ]


def build_messages_qwen(conv_input: ConversationInput) -> list[dict]:
    """Build messages for Qwen3.5 (and Qwen3) models with thinking mode disabled.

    Qwen3.5 hybrid-thinking checkpoints can prepend a ``<think>...</think>``
    block to every response.  Appending ``/no_think`` at the end of the user
    turn is the documented format-level directive that suppresses this prefix
    (see https://huggingface.co/Qwen/Qwen3.5-docs — "Thinking mode control").
    It is a safe no-op on older / non-thinking Qwen variants (0.6B, Qwen3-0.6B).

    System prompt content and user content are completely unchanged; only the
    trailing ``\\n\\n/no_think`` token is appended to the last user message.
    ``chat_format="chatml"`` is set by LocalEngine when a Qwen model is detected.
    """
    messages = build_messages(conv_input)
    messages[-1]["content"] += "\n\n/no_think"
    return messages


def build_messages_gemma(conv_input: ConversationInput) -> list[dict]:
    """Build messages for Google Gemma (Gemma 2 / 3 / 4 IT, etc.) with llama.cpp / llama-cpp-python.

    Gemma uses turns: ``<start_of_turn>user`` … ``<end_of_turn>`` then ``<start_of_turn>model`` …
    (see https://github.com/ggml-org/llama.cpp/wiki/Templates-supported-by-llama_chat_apply_template — template ``gemma``).

    ``llama-cpp-python``'s ``chat_format="gemma"`` does not emit ``role=system`` content (it is dropped).
    We merge the system instructions into the single user turn so behavior matches Llama-style APIs.
    """
    system = build_system_prompt(conv_input, user_default_profile=conv_input.profile)
    user = build_user_prompt(conv_input)
    merged = f"{system}\n\n---\n\n{user}"
    return [{"role": "user", "content": merged}]


def format_gemma_chat_prompt(merged_user_content: str) -> str:
    """Exact single-turn string ``chat_format='gemma'`` produces before BOS handling (for debugging).

    The runtime adds the model generation header; this matches ``format_gemma`` in upstream
    ``llama_chat_format.py`` for one user message and an empty assistant turn.
    """
    body = merged_user_content.strip()
    sep = "<end_of_turn>\n"
    return f"<start_of_turn>user\n{body}{sep}<start_of_turn>model\n"
