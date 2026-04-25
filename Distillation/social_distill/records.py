"""Merge parsed model JSON with curriculum plan."""

from __future__ import annotations

from typing import Any

from .constants import INPUT_PROVENANCE_HUMAN_SEEDED, INPUT_PROVENANCE_SYNTHETIC
from .validation import validate_input_record, validate_record


def merge_record(parsed: dict[str, Any], plan: dict[str, Any], sample_id: str) -> dict[str, Any]:
    row = {
        "sample_id": sample_id,
        "task_type": plan["task_type"],
        "suggestion_theme": plan["suggestion_theme"],
        "self_id": "me",
        "participants": parsed["participants"],
        "conversation": parsed["conversation"],
        "reply_to": parsed["reply_to"],
        "conversation_profile": parsed["conversation_profile"],
        "draft": parsed.get("draft", ""),
        "target": parsed["target"],
        "distillation_controls": plan["distillation_controls"],
        "metadata": {
            "source": "claude_distilled",
            "split": "train",
            "format_validated": True,
        },
    }
    validate_record(row, plan)
    return row


def merge_input_record(parsed: dict[str, Any], plan: dict[str, Any], sample_id: str) -> dict[str, Any]:
    if "target" in parsed:
        raise ValueError('input-only generation must not include "target"')
    prov = plan.get("input_provenance", INPUT_PROVENANCE_SYNTHETIC)
    row: dict[str, Any] = {
        "sample_id": sample_id,
        "input_provenance": prov,
        "task_type": plan["task_type"],
        "suggestion_theme": plan["suggestion_theme"],
        "self_id": "me",
        "participants": parsed["participants"],
        "conversation": parsed["conversation"],
        "reply_to": parsed["reply_to"],
        "conversation_profile": parsed["conversation_profile"],
        "draft": parsed.get("draft", ""),
        "distillation_controls": plan["distillation_controls"],
        "metadata": {
            "source": "claude_distilled_input",
            "split": "train",
            "format_validated": True,
            "input_provenance": prov,
        },
    }
    validate_input_record(row, plan)
    return row


def ingest_human_seeded_input_row(raw: dict[str, Any], plan: dict[str, Any], sample_id: str) -> dict[str, Any]:
    """
    Normalize a curator-provided JSON object into the same input shape as ``merge_input_record`` output.
    Curriculum fields (task_type, suggestion_theme, profiles, controls) are taken from ``plan`` so rows
    align with the diversity schedule; conversation/participants/draft come from ``raw``.
    """
    data = dict(raw)
    if data.get("target"):
        raise ValueError('human-seeded input rows must not include a "target"')
    data.pop("target", None)
    data["sample_id"] = sample_id
    data["task_type"] = plan["task_type"]
    data["suggestion_theme"] = plan["suggestion_theme"]
    data["distillation_controls"] = plan["distillation_controls"]
    data["conversation_profile"] = plan["conversation_profile"]
    data.setdefault("self_id", "me")
    data["input_provenance"] = INPUT_PROVENANCE_HUMAN_SEEDED
    md = dict(data.get("metadata") or {})
    md.setdefault("split", "train")
    md["format_validated"] = True
    md["input_provenance"] = INPUT_PROVENANCE_HUMAN_SEEDED
    md.setdefault("source", "human_seeded_input")
    data["metadata"] = md
    validate_input_record(data, plan)
    return data
