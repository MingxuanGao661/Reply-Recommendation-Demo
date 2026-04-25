"""Validate input-only rows and full rows with suggestions."""

from __future__ import annotations

import re
from typing import Any

from .constants import ANTI_CLICHE_PHRASES, DECISION_WORD_BOUNDS, OVERPOLITE_PHRASES
from .text_analysis import (
    contains_any_phrase,
    detail_budget_for_risk,
    extract_detail_markers,
    validate_reply_styles_suggestions,
    validate_suggestion_strategy_distinct,
)


def infer_plan_from_row(row: dict[str, Any]) -> dict[str, Any]:
    speakers = {m["speaker"] for m in row.get("conversation", [])}
    return {
        "task_type": row["task_type"],
        "suggestion_theme": row["suggestion_theme"],
        "is_group": len(speakers) > 2,
        "conversation_profile": row["conversation_profile"],
    }


def validate_input_record(row: dict[str, Any], plan: dict[str, Any]) -> None:
    if row.get("task_type") != plan["task_type"]:
        raise ValueError("task_type drift vs plan")
    if row.get("suggestion_theme") != plan["suggestion_theme"]:
        raise ValueError("suggestion_theme drift vs plan")
    conv = row.get("conversation")
    if not conv or not isinstance(conv, list):
        raise ValueError("missing conversation")
    last = conv[-1]
    if last.get("speaker") != row.get("reply_to"):
        raise ValueError("last message speaker must equal reply_to")
    tt = plan["task_type"]
    draft = str(row.get("draft", ""))
    if tt in ("from_scratch", "decision") and draft.strip():
        raise ValueError("draft must be empty for from_scratch/decision")
    if tt == "rewrite" and not draft.strip():
        raise ValueError("draft required for rewrite")
    prof = row.get("conversation_profile") or {}
    if prof.get("tone") != plan["conversation_profile"]["tone"]:
        raise ValueError("conversation_profile.tone drift")
    if prof.get("length") != plan["conversation_profile"]["length"]:
        raise ValueError("conversation_profile.length drift")
    speakers = {m["speaker"] for m in conv}
    if plan["is_group"]:
        if len(speakers) < 3:
            raise ValueError("group chat needs >=3 speakers in conversation")
    else:
        if len(speakers) > 2:
            raise ValueError("1-on-1 chat should have at most 2 speakers in conversation")


def validate_record(row: dict[str, Any], plan: dict[str, Any]) -> None:
    validate_input_record(row, plan)
    theme = plan["suggestion_theme"]
    expected_labels = (
        {"Direct", "Friendly", "Thoughtful"}
        if theme == "replyStyles"
        else {"Agree", "Soft Decline", "Delay"}
    )
    sug = row.get("target", {}).get("suggestions")
    if not isinstance(sug, list) or len(sug) != 3:
        raise ValueError("target.suggestions must be list of 3")
    got = {s.get("label") for s in sug}
    if got != expected_labels:
        raise ValueError(f"label set mismatch: got {got} want {expected_labels}")
    text_by_label: dict[str, str] = {}
    word_count_by_label: dict[str, int] = {}
    for s in sug:
        label = str(s.get("label", ""))
        txt = str(s.get("text", "")).strip()
        if not txt:
            raise ValueError("empty suggestion text")
        text_by_label[label] = txt
        word_count_by_label[label] = len(re.findall(r"\b[\w']+\b", txt))
        if any(ch in txt for ch in ("😀", "😄", "😂", "😍", "🥲", "😉", "😭", "😅", "🙂", "🙃", "🤔", "🤝", "🙏", "❤️", "❤", "👍", "👀", "✨", "🎉", "💀")):
            raise ValueError("emoji not allowed in suggestions")
        # Allow dash punctuation; this was causing too many false negatives.
        found_cliche = contains_any_phrase(txt, ANTI_CLICHE_PHRASES)
        if found_cliche:
            raise ValueError(f'anti-cliche blacklist phrase found: "{found_cliche}"')
        found_overpolite = contains_any_phrase(txt, OVERPOLITE_PHRASES)
        if found_overpolite and len(txt.split()) > 24:
            raise ValueError(f'overly formal phrase found: "{found_overpolite}"')
    validate_suggestion_strategy_distinct(theme, text_by_label)
    conv = row.get("conversation")
    assert conv and isinstance(conv, list)
    conv_markers = extract_detail_markers("\n".join(str(m.get("text", "")) for m in conv))
    if row.get("suggestion_theme") == "decisionReply":
        for lbl, (lo, hi) in DECISION_WORD_BOUNDS.items():
            wc = word_count_by_label.get(lbl, 0)
            if not (lo <= wc <= hi):
                raise ValueError(f"{lbl} length out of range: {wc} words (expected {lo}-{hi})")
        counts = sorted(word_count_by_label.values())
        if len(counts) == 3 and (counts[-1] - counts[0] < 2):
            raise ValueError("decisionReply outputs too symmetric in length")
    if row.get("suggestion_theme") == "replyStyles":
        validate_reply_styles_suggestions(text_by_label, word_count_by_label)
    social_risk = (row.get("distillation_controls") or {}).get("social_risk")
    detail_budget = detail_budget_for_risk(social_risk)
    for label, txt in text_by_label.items():
        msg_markers = extract_detail_markers(txt)
        novel = msg_markers - conv_markers
        if len(novel) > detail_budget:
            raise ValueError(
                f'{label} adds too many ungrounded details for risk={social_risk}: '
                f"{sorted(novel)} (budget {detail_budget})"
            )
