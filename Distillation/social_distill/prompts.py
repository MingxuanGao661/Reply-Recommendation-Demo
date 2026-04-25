"""System/user strings for meta input generation and demo-aligned teacher."""

from __future__ import annotations

import json
from typing import Any, Literal

from .constants import (
    LABEL_LISTS,
    QUALITY_CONSTRAINTS,
    RELATIONSHIP_DISTANCE,
    SCENE_TAGS,
    SOCIAL_RISK,
    THEME_RULES,
)
from .text_analysis import detail_budget_for_risk


def build_style_block(conv_profile: dict[str, Any] | None, user_profile: dict[str, Any] | None) -> str:
    cp = conv_profile or {}
    up = user_profile or {}
    c_tone = cp.get("tone") or "not set (this chat does not override)"
    c_len = cp.get("length") or "not set (this chat does not override)"
    u_tone = up.get("tone") or "not set (no personal preference on this axis)"
    u_len = up.get("length") or "not set (no personal preference on this axis)"
    eff_tone = cp.get("tone") or up.get("tone") or "warm"
    eff_len = cp.get("length") or up.get("length") or "short"
    return (
        "- Style — honor BOTH the user's personal preferences AND this conversation's settings:\n"
        f"  • Personal (user, app-wide): tone: {u_tone} | length: {u_len}\n"
        f"  • This conversation / thread: tone: {c_tone} | length: {c_len}\n"
        f"  • Use for THIS reply (per axis: conversation value if set, else personal, else app default warm/short): "
        f"Tone: {eff_tone} | Length: {eff_len}"
    )


def build_distillation_controls_user_suffix(sample: dict[str, Any]) -> str:
    dc = sample.get("distillation_controls")
    if not isinstance(dc, dict):
        return ""
    lines = []
    st = dc.get("scene_tag")
    if st in SCENE_TAGS:
        lines.append(f"scene_tag: {st}")
    sr = dc.get("social_risk")
    if sr in SOCIAL_RISK:
        lines.append(f"social_risk: {sr}")
    rd = dc.get("relationship_distance")
    if rd in RELATIONSHIP_DISTANCE:
        lines.append(f"relationship_distance: {rd}")
    if not lines:
        return ""
    return (
        "\n\nGeneration controls (do not mention these labels in the JSON output; "
        "use them only to tune tone and strategy):\n" + "\n".join(f"- {x}" for x in lines)
    )


def _teacher_shared_quality_text() -> str:
    """Identical across all teacher calls in a run — placed first for prompt caching."""
    return (
        "The following constraints apply to every suggestions generation in this task.\n\n"
        + QUALITY_CONSTRAINTS
    )


def _build_teacher_system_dynamic(sample: dict[str, Any], user_profile: dict[str, Any] | None) -> str:
    """Per-row teacher system instructions (after the shared cached quality block)."""
    has_draft = bool(str(sample.get("draft", "")).strip())
    theme = sample.get("suggestion_theme", "replyStyles")
    social_risk = (sample.get("distillation_controls") or {}).get("social_risk", "medium")
    budget = detail_budget_for_risk(social_risk)
    participants = {p["id"]: p["name"] for p in sample.get("participants", [])}
    reply_to_id = sample.get("reply_to")
    reply_to_name = participants.get(reply_to_id) if reply_to_id else None
    style_block = build_style_block(sample.get("conversation_profile"), user_profile)
    theme_rules = THEME_RULES[theme]
    label_list = LABEL_LISTS[theme]
    reply_target = f"{reply_to_name}'s message" if reply_to_name else "the last message in the conversation"
    if has_draft:
        return (
            f'Complete "Me (typing)" into 3 send-ready messages for {reply_target}.\n\n'
            f"{style_block}\n{theme_rules}\n\n"
            "Rules:\n"
            '- "Me (typing)" is YOUR OWN partial text — each output is a polished version of it. Do NOT reply to it; '
            "it is not someone else's message.\n"
            "- Keep the core meaning: same yes/no, same times/dates, same intent. Do NOT flip or reverse the draft's answer.\n"
            f"- The completed text must fit as a reply to {reply_target}. Real texting — short and casual unless length is long.\n\n"
            f"- Evidence anchoring: do NOT invent specific facts (time/place/reason) not present in the conversation. "
            f"Social risk is {social_risk}; allow at most {budget} new concrete detail marker(s).\n"
            f'Output format: one JSON object only, no markdown. Key "suggestions" = array of exactly 3 objects. '
            f'Each has "label" ({label_list}) and "text".'
        )
    return (
        "Suggest 3 texts Me can send. Answer the OTHER person's last message.\n\n"
        f"{style_block}\n{theme_rules}\n\n"
        "Rules:\n"
        f"- Address {reply_target} directly. If they asked a question, answer it; do not only repeat what they said.\n"
        "- Obey the Style rules above. Short, casual, real person texting unless length is long. "
        "Avoid unnecessary exclamation marks (!).\n"
        f"- Evidence anchoring: do NOT invent specific facts (time/place/reason) not present in the conversation. "
        f"Social risk is {social_risk}; allow at most {budget} new concrete detail marker(s).\n\n"
        f'Output format: one JSON object only, no markdown. Key "suggestions" = array of exactly 3 objects. '
        f'Each has "label" ({label_list}) and "text" (Me\'s real reply for THIS chat).\n\n'
        'Do NOT reuse the same canned line for all three. Do NOT default to "yeah sounds good" or "down" unless they truly fit the thread.'
    )


def build_teacher_system_param_blocks(
    sample: dict[str, Any],
    user_profile: dict[str, Any] | None,
    *,
    cache_ttl: Literal["5m", "1h"] = "1h",
) -> list[dict[str, Any]]:
    """Two-block system prompt: shared quality text (prompt-cached) + per-row dynamic instructions."""
    return [
        {
            "type": "text",
            "text": _teacher_shared_quality_text(),
            "cache_control": {"type": "ephemeral", "ttl": cache_ttl},
        },
        {"type": "text", "text": _build_teacher_system_dynamic(sample, user_profile)},
    ]


def build_teacher_system_prompt(sample: dict[str, Any], user_profile: dict[str, Any] | None) -> str:
    """Single-string teacher system (same semantics as cached two-block version, concatenated)."""
    return _teacher_shared_quality_text() + "\n\n" + _build_teacher_system_dynamic(sample, user_profile)


def build_teacher_user_prompt(sample: dict[str, Any]) -> str:
    self_id = sample.get("self_id", "me")
    participants = {p["id"]: p["name"] for p in sample.get("participants", [])}
    reply_to_id = sample.get("reply_to")
    reply_to_name = participants.get(reply_to_id) if reply_to_id else None
    lines: list[str] = []
    conv = sample.get("conversation") or []
    unique_speakers = {m["speaker"] for m in conv}
    if len(unique_speakers) > 2:
        others = [p["name"] for p in sample.get("participants", []) if not p.get("is_self")]
        lines.append(f"Group chat with: {', '.join(others)}")
        lines.append("")
    lines.append("Conversation:")
    for msg in conv:
        name = "Me" if msg["speaker"] == self_id else participants.get(msg["speaker"], msg["speaker"])
        lines.append(f"  {name}: {msg['text']}")
    has_draft = bool(str(sample.get("draft", "")).strip())
    if has_draft:
        lines.append(f'  Me (typing): "{str(sample.get("draft", "")).strip()}"')
        lines.append("")
        if reply_to_name:
            lines.append(f'Complete "Me (typing)" into a ready-to-send reply to {reply_to_name}.')
        else:
            lines.append('Complete "Me (typing)" into a ready-to-send reply.')
    else:
        target_msg = None
        for m in reversed(conv):
            if m["speaker"] == reply_to_id:
                target_msg = m
                break
        if target_msg is None and conv:
            target_msg = conv[-1]
        target_name = reply_to_name or "them"
        if target_msg:
            lines.append(f'\nReply ONLY to this message from {target_name}: "{target_msg["text"]}"')
        elif reply_to_name:
            lines.append(f"\nReplying to: {reply_to_name}")
        lines.append("(no draft — write a fresh reply)")
    lines.append(build_distillation_controls_user_suffix(sample))
    lines.append("\nReply in JSON as instructed.")
    return "\n".join(lines)


META_SYSTEM = """You are generating one row of JSONL training data for a social texting reply model.
Output a single JSON object only — no markdown fences, no commentary.

The object MUST use exactly these top-level keys:
  "participants", "conversation", "reply_to", "conversation_profile", "draft", "target"

Rules:
- "participants": array of {id, name, is_self, relationship}. Include "me" with is_self true. Others: is_self false.
  Use stable ids: "me", "alice", "bob", "charlie" as needed. Names can be human display names.
- "conversation": array of {speaker, text} using those ids. Max 10 messages. Realistic texting.
  The LAST message must be from the speaker named by "reply_to" (not "me").
- "reply_to": id string — who Me is replying to (must match last message speaker).
- "conversation_profile": must match the fixed tone and length given in the user message exactly.
- "draft": empty string "" for from_scratch and decision; non-empty realistic partial draft for rewrite only.
- "target": {"suggestions": [ {"label": ..., "text": ...}, x3 ]}
  Labels must match suggestion_theme exactly (case and spacing):
    replyStyles -> Direct, Friendly, Thoughtful
    decisionReply -> Agree, Soft Decline, Delay
- For group chats: at least 3 distinct speaker ids in conversation; reply_to is one non-me speaker.
- For decision / decisionReply: last message should invite a clear yes/no or tonight/plan commitment.
- For rewrite: prior context + other person's last message; draft is Me's typing continuation (do not duplicate as a full sent message from me after others).
- For replyStyles target.suggestions: keep Direct/Friendly/Thoughtful short. Thoughtful must be a single short sentence (roughly <=18 words, <=1 comma), not a reflective mini-essay or therapist-like closure.
- For replyStyles: Direct/Thoughtful must not use style-heavy slang (ngl, tbh, fr, lowkey, bet, …); each may use at most one ultra-light marker (idk, rn, lmk). Friendly may use style-heavy + ultra-light markers in moderation (not stacked).
- For target.suggestions in general: each line should do ONE thing only (comfort OR answer OR propose OR next step, not a bundle). Do not sound like a model demonstrating emotional intelligence.
"""

META_INPUT_SYSTEM = """You are generating one JSON object for a texting-reply **dataset input** (conversation only).
Output a single JSON object only — no markdown fences, no commentary.

The object MUST use exactly these top-level keys (no "target", no suggestions):
  "participants", "conversation", "reply_to", "conversation_profile", "draft"

Rules:
- "participants": array of {id, name, is_self, relationship}. Include "me" with is_self true. Others: is_self false.
  Use stable ids: "me", "alice", "bob", "charlie" as needed. Names can be human display names.
- "conversation": array of {speaker, text} using those ids. Max 10 messages. Realistic texting.
  The LAST message must be from the speaker named by "reply_to" (not "me").
- "reply_to": id string — who Me is replying to (must match last message speaker).
- "conversation_profile": must match the fixed tone and length given in the user message exactly.
- "draft": empty string "" for from_scratch and decision; non-empty realistic partial draft for rewrite only.
- For group chats: at least 3 distinct speaker ids in conversation; reply_to is one non-me speaker.
- For decision / decisionReply: last message should invite a clear yes/no or tonight/plan commitment.
- For rewrite: prior context + other person's last message; draft is Me's typing continuation (do not duplicate as a full sent message from me after others).
- Do NOT output suggestions, labels, or a "target" key — only the thread and draft.
"""


def build_meta_user_prompt(plan: dict[str, Any]) -> str:
    chat = "group" if plan["is_group"] else "1-on-1"
    prof = plan["conversation_profile"]
    dc = plan["distillation_controls"]
    return f"""Fixed plan (match exactly; we will overwrite task_type / suggestion_theme if you diverge):
- task_type: {plan["task_type"]}
- suggestion_theme: {plan["suggestion_theme"]}
- relationship (for the person Me replies to, in participants): {plan["relationship"]}
- chat_type: {chat}
- approximate_turns: {plan["approx_turns"]} (2–10; prefer short threads)
- conversation_profile.tone: {prof["tone"]}
- conversation_profile.length: {prof["length"]}
- distillation_controls (shape vibe only; never echo these keys in message text): {json.dumps(dc)}

Generate one realistic sample. Remember: last conversation line is from reply_to, not me.
For chat_type=group, enforce at least 3 distinct speakers in conversation including me, and at least 2 non-me speakers.
Do not force extra specifics. If context is underspecified, keep replies naturally brief instead of guessing details.
If suggestion_theme is replyStyles: target.suggestions word caps: Direct <=14, Friendly <=22, Thoughtful <=18 (Thoughtful: one sentence, max one comma, no therapist-y reflection).
If suggestion_theme is replyStyles: Friendly may use style-heavy slang lightly; Direct/Thoughtful: no style-heavy slang, at most one of idk/rn/lmk each; the three lines must differ in strategy, not be the same sentence tweaked.
"""


def build_meta_input_user_prompt(plan: dict[str, Any]) -> str:
    chat = "group" if plan["is_group"] else "1-on-1"
    prof = plan["conversation_profile"]
    dc = plan["distillation_controls"]
    return f"""Fixed plan (match exactly; we will overwrite task_type / suggestion_theme if you diverge):
- task_type: {plan["task_type"]}
- suggestion_theme: {plan["suggestion_theme"]}
- relationship (for the person Me replies to, in participants): {plan["relationship"]}
- chat_type: {chat}
- approximate_turns: {plan["approx_turns"]} (2–10; prefer short threads)
- conversation_profile.tone: {prof["tone"]}
- conversation_profile.length: {prof["length"]}
- distillation_controls (shape vibe only; never echo these keys in message text): {json.dumps(dc)}

Generate one realistic sample. Remember: last conversation line is from reply_to, not me.
For chat_type=group, enforce at least 3 distinct speakers in conversation including me, and at least 2 non-me speakers.
Do not force extra specifics. If context is underspecified, keep messages naturally brief instead of guessing details.
Output ONLY participants, conversation, reply_to, conversation_profile, and draft — no suggestions.
"""
