"""Run-level counters and JSON summary for distill outputs."""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from typing import Any

from .constants import INPUT_PROVENANCE_SYNTHETIC
from .text_analysis import friendly_has_any_slang


def reply_to_relationship(row: dict[str, Any]) -> str:
    rt = row.get("reply_to")
    for p in row.get("participants", []) or []:
        if p.get("id") == rt:
            return str(p.get("relationship", "missing"))
    return "missing"


def suggestions_json(sugs: Any) -> str:
    return json.dumps(sugs, ensure_ascii=False, sort_keys=True)


def failure_bucket(err: str | None) -> str:
    e = (err or "").lower()
    if "too similar" in e or "first clauses too similar" in e:
        return "strategy_distinctness"
    if "style-heavy" in e or "ultra-light" in e or "too many slang" in e:
        return "slang_marker_rules"
    if "thoughtful" in e and any(
        x in e for x in ("word", "comma", "sentence", "therapist", "coordinating", "too long")
    ):
        return "thoughtful_shape"
    if "direct" in e and "word" in e:
        return "direct_word_cap"
    if "friendly" in e and "word" in e:
        return "friendly_word_cap"
    if "length out of range" in e:
        return "decision_word_bounds"
    if "too symmetric" in e:
        return "decision_symmetry"
    if "ungrounded details" in e or ("detail" in e and "budget" in e):
        return "detail_budget"
    if "emoji" in e or "dash punctuation" in e:
        return "format_tokens"
    if "anti-cliche" in e or "blacklist phrase" in e:
        return "anti_cliche"
    if "overly formal" in e:
        return "overpolite"
    if "mismatch" in e or "drift" in e:
        return "plan_mismatch"
    if "json" in e or "parse" in e or "extract" in e:
        return "parse_or_json"
    return "other"


def record_row_into_stats(row: dict[str, Any], stats: dict[str, Any]) -> None:
    stats["n_written"] += 1
    stats["by_input_provenance"][row.get("input_provenance", INPUT_PROVENANCE_SYNTHETIC)] += 1
    stats["by_task"][row["task_type"]] += 1
    stats["by_theme"][row["suggestion_theme"]] += 1
    stats["by_relationship"][reply_to_relationship(row)] += 1
    prof = row.get("conversation_profile") or {}
    stats["by_tone"][str(prof.get("tone", "missing"))] += 1
    stats["by_length"][str(prof.get("length", "missing"))] += 1
    theme = row["suggestion_theme"]
    for s in row["target"]["suggestions"]:
        lbl = str(s.get("label", ""))
        txt = str(s.get("text", ""))
        wc = len(re.findall(r"\b[\w']+\b", txt))
        stats["word_sum"][lbl] += wc
        stats["word_n"][lbl] += 1
    if theme == "replyStyles":
        stats["replystyles_rows"] += 1
        th_txt = next((str(s.get("text", "")) for s in row["target"]["suggestions"] if s.get("label") == "Thoughtful"), "")
        if len(re.findall(r"\b[\w']+\b", th_txt)) > 18:
            stats["thoughtful_gt18"] += 1
        fb = next((str(s.get("text", "")) for s in row["target"]["suggestions"] if s.get("label") == "Friendly"), "")
        if friendly_has_any_slang(fb):
            stats["friendly_slang"] += 1


def build_run_summary(
    stats: dict[str, Any],
    plans_n: int,
    generate_ok: int,
    args: argparse.Namespace,
) -> dict[str, Any]:
    n = stats["n_written"]
    avg_by_label: dict[str, float] = {}
    for lbl in sorted(stats["word_n"].keys()):
        c = stats["word_n"][lbl]
        if c:
            avg_by_label[lbl] = round(stats["word_sum"][lbl] / c, 3)
    rs = stats["replystyles_rows"]
    summary: dict[str, Any] = {
        "plans_total": plans_n,
        "phase1_inputs_generate_ok_count": generate_ok,
        "phase2_targets_generate_ok_count": stats.get("targets_ok", 0),
        "n_written": n,
        "targets_by_input_provenance": dict(stats.get("by_input_provenance", {})),
        "by_task_type": dict(stats["by_task"]),
        "by_suggestion_theme": dict(stats["by_theme"]),
        "relationship_distribution": dict(stats["by_relationship"]),
        "tone_distribution": dict(stats["by_tone"]),
        "length_distribution": dict(stats["by_length"]),
        "average_words_by_label": avg_by_label,
        "pct_replystyles_thoughtful_word_count_gt_18": round(100.0 * stats["thoughtful_gt18"] / rs, 2)
        if rs
        else None,
        "pct_replystyles_friendly_with_any_slang": round(100.0 * stats["friendly_slang"] / rs, 2) if rs else None,
        "teacher_target_generation": {
            "rows_attempted": stats["teacher_pass_invoked"],
            "rows_failed_no_valid_target": stats["teacher_pass_fallback"],
            "failure_rate": round(stats["teacher_pass_fallback"] / stats["teacher_pass_invoked"], 4)
            if stats["teacher_pass_invoked"]
            else None,
            "targets_written_validation_relaxed_count": stats.get("targets_validation_relaxed", 0),
        },
        "phase1_inputs": {
            "generate_ok_count": stats.get("phase1_ok", 0),
            "plans_total": stats.get("phase1_plans", plans_n),
            "by_input_provenance": dict(stats.get("phase1_by_provenance", {})),
        },
        "top_validation_failure_buckets": stats["failure_buckets"].most_common(20),
        "cli": {
            "total": getattr(args, "total", None),
            "limit": getattr(args, "limit", None),
            "teacher_retries": getattr(args, "teacher_retries", None),
            "phase2_message_batch": getattr(args, "phase2_message_batch", False),
            "phase2_batch_rescue": getattr(args, "phase2_batch_rescue", False),
            "phase2_batch_chunk_size": getattr(args, "phase2_batch_chunk_size", None),
            "phase2_batch_poll_seconds": getattr(args, "phase2_batch_poll_seconds", None),
            "phase2_resume": getattr(args, "phase2_resume", False),
            "skip_phase_1": getattr(args, "skip_phase_1", False),
            "input_provenance": getattr(args, "input_provenance", None),
            "human_seeded_inputs": str(getattr(args, "human_seeded_inputs", "") or ""),
            "inputs_out": str(getattr(args, "inputs_out", "")),
            "targets_out": str(getattr(args, "targets_out", "")),
            "merged_out": str(getattr(args, "merged_out", "") or ""),
        },
    }
    return summary
