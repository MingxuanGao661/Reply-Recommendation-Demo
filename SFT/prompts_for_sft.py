"""
将 social_2000_merged.jsonl 单条记录转为与 iOS PromptBuilder 一致的 system / user 文本。
无 draft 时 theme 使用数据字段 suggestion_theme，以保证与 target 标签一致。
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from textwrap import dedent
from typing import Any, Dict, List, Optional

REPLY_STYLE_LABELS = ["Direct", "Friendly", "Thoughtful"]
DECISION_LABELS = ["Agree", "Soft Decline", "Delay"]

SYSTEM_WITH_DRAFT = dedent(
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

SYSTEM_NO_DRAFT = dedent(
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


def _merged_profile(
    conversation_profile: Optional[Dict[str, Any]], user_default: Optional[Dict[str, str]]
) -> tuple[str, str]:
    c_tone = (conversation_profile or {}).get("tone")
    c_len = (conversation_profile or {}).get("length")
    u_tone = (user_default or {}).get("tone") if user_default else None
    u_len = (user_default or {}).get("length") if user_default else None
    eff_tone = c_tone or u_tone or "warm"
    eff_len = c_len or u_len or "short"
    return eff_tone, eff_len


def style_rules_block(
    user_default: Optional[Dict[str, str]],
    conversation_profile: Optional[Dict[str, Any]],
    effective_tone: str,
    effective_length: str,
) -> str:
    u_tone = user_default.get("tone") if user_default and user_default.get("tone") else None
    u_len = user_default.get("length") if user_default and user_default.get("length") else None
    c_tone = (conversation_profile or {}).get("tone")
    c_len = (conversation_profile or {}).get("length")

    u_tone_s = u_tone or "not set (no personal preference on this axis)"
    u_len_s = u_len or "not set (no personal preference on this axis)"
    c_tone_s = c_tone or "not set (this chat does not override)"
    c_len_s = c_len or "not set (this chat does not override)"

    return dedent(
        f"""
    - Style — honor BOTH the user's personal preferences AND this conversation's settings:
      • Personal (user, app-wide): tone: {u_tone_s} | length: {u_len_s}
      • This conversation / thread: tone: {c_tone_s} | length: {c_len_s}
      • Use for THIS reply (per axis: conversation value if set, else personal, else app default warm/short): Tone: {effective_tone} | Length: {effective_length}
    """
    ).strip()


def quoted_label_list(labels: List[str]) -> str:
    return ", ".join(f'"{x}"' for x in labels)


def resolve_theme_key(record: Dict[str, Any]) -> str:
    """与 App 一致：有 draft 时固定 replyStyles；否则用数据集中 theme（与标注一致）。"""
    draft = (record.get("draft") or "").strip()
    if draft:
        return "replyStyles"
    st = record.get("suggestion_theme") or "replyStyles"
    if st == "decisionReply":
        return "decisionReply"
    return "replyStyles"


def theme_rules_block(theme_key: str) -> str:
    return THEME_DECISION if theme_key == "decisionReply" else THEME_REPLY_STYLES


def labels_for_theme(theme_key: str) -> List[str]:
    return DECISION_LABELS if theme_key == "decisionReply" else REPLY_STYLE_LABELS


def display_name(
    speaker_id: str, self_id: str, participants: List[Dict[str, Any]]
) -> str:
    if speaker_id == self_id:
        return "Me"
    for p in participants:
        if p.get("id") == speaker_id:
            return str(p.get("name") or speaker_id)
    return speaker_id


def reply_target_message(conversation: List[Dict], reply_to: Optional[str]) -> Optional[Dict]:
    if not reply_to or not conversation:
        return None
    for msg in reversed(conversation):
        if msg.get("speaker") == reply_to:
            return msg
    return None


def is_group_chat(conversation: List[Dict]) -> bool:
    return len({m.get("speaker") for m in conversation}) > 2


def build_system_prompt(
    record: Dict[str, Any],
    user_default: Optional[Dict[str, str]] = None,
) -> str:
    conv_profile = record.get("conversation_profile")
    eff_tone, eff_len = _merged_profile(conv_profile, user_default)
    style_block = style_rules_block(user_default, conv_profile, eff_tone, eff_len)

    draft = (record.get("draft") or "").strip()
    has_draft = bool(draft)
    theme_key = resolve_theme_key(record)
    labels = labels_for_theme(theme_key)

    reply_to = record.get("reply_to")
    participants = record.get("participants") or []
    self_id = record.get("self_id") or "me"
    reply_target_name = display_name(reply_to, self_id, participants) if reply_to else None
    if reply_target_name:
        target = f"{reply_target_name}'s message"
    else:
        target = "the last message in the conversation"

    template = SYSTEM_WITH_DRAFT if has_draft else SYSTEM_NO_DRAFT
    return (
        template.replace("{style_rules_block}", style_block)
        .replace("{theme_rules_block}", theme_rules_block(theme_key))
        .replace("{label_list}", quoted_label_list(labels))
        .replace("{reply_target}", target)
    )


def build_user_prompt(record: Dict[str, Any]) -> str:
    conversation = record.get("conversation") or []
    participants = record.get("participants") or []
    self_id = record.get("self_id") or "me"
    reply_to = record.get("reply_to")
    draft = (record.get("draft") or "").strip()
    has_draft = bool(draft)

    lines: List[str] = []
    if is_group_chat(conversation) and participants:
        names = [
            str(p.get("name") or p.get("id"))
            for p in participants
            if not p.get("is_self")
        ]
        lines.append(f"Group chat with: {', '.join(names)}")
        lines.append("")

    lines.append("Conversation:")
    for msg in conversation:
        name = display_name(msg["speaker"], self_id, participants)
        lines.append(f"  {name}: {msg['text']}")

    reply_target_name = display_name(reply_to, self_id, participants) if reply_to else None

    if has_draft:
        lines.append(f'  Me (typing): "{draft}"')
        lines.append("")
        if reply_target_name:
            lines.append(
                f'Complete "Me (typing)" into a ready-to-send reply to {reply_target_name}.'
            )
        else:
            lines.append('Complete "Me (typing)" into a ready-to-send reply.')
    else:
        tgt_msg = reply_target_message(conversation, reply_to)
        if tgt_msg:
            tn = reply_target_name or "them"
            lines.append(f'\nReply ONLY to this message from {tn}: "{tgt_msg["text"]}"')
        elif reply_target_name:
            lines.append(f"\nReplying to: {reply_target_name}")
        lines.append("(no draft — write a fresh reply)")

    lines.append("\nReply in JSON as instructed.")
    return "\n".join(lines)


def assistant_content_from_record(record: Dict[str, Any]) -> str:
    suggestions = record["target"]["suggestions"]
    payload = {"suggestions": [{"label": s["label"], "text": s["text"]} for s in suggestions]}
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def record_to_messages(
    record: Dict[str, Any],
    user_default: Optional[Dict[str, str]] = None,
) -> List[Dict[str, str]]:
    return [
        {"role": "system", "content": build_system_prompt(record, user_default)},
        {"role": "user", "content": build_user_prompt(record)},
        {"role": "assistant", "content": assistant_content_from_record(record)},
    ]
