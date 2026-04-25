"""Claude API calls: input-only scene, teacher targets, optional depolish."""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from typing import Any

from .prompts import (
    META_INPUT_SYSTEM,
    build_meta_input_user_prompt,
    build_teacher_system_param_blocks,
    build_teacher_user_prompt,
)
from .records import merge_input_record
from .utils import extract_json_object
from .validation import infer_plan_from_row, validate_record


@dataclass
class GenResult:
    index: int
    ok: bool
    row: dict[str, Any] | None
    error: str | None = None
    #: Batch teacher: assistant body when ``ok`` is False (for manual review).
    raw_assistant_text: str | None = None
    #: When ``ok`` and ``row`` are set: ``False`` means ``validate_record`` failed but suggestions were kept.
    validated: bool = True
    validation_error: str | None = None


def call_claude_json(
    client: Any,
    model: str,
    system: str | list[dict[str, Any]],
    user: str,
    max_tokens: int = 4096,
    temperature: float = 0.85,
) -> str:
    resp = client.messages.create(
        model=model,
        max_tokens=max_tokens,
        temperature=temperature,
        system=system,
        messages=[{"role": "user", "content": user}],
    )
    if not resp.content:
        return ""
    block = resp.content[0]
    if block.type != "text":
        return ""
    return block.text


def depolish_suggestions(
    client: Any,
    model: str,
    row: dict[str, Any],
    max_retries: int = 2,
) -> dict[str, Any]:
    """Optional rewrite for **human screening** (see `depolish-screen`); not used in the default distill pipeline."""
    theme = row["suggestion_theme"]
    label_set = "Direct, Friendly, Thoughtful" if theme == "replyStyles" else "Agree, Soft Decline, Delay"
    conv_lines: list[str] = []
    participants = {p["id"]: p["name"] for p in row.get("participants", [])}
    for m in row.get("conversation", []):
        speaker = "Me" if m["speaker"] == row.get("self_id", "me") else participants.get(m["speaker"], m["speaker"])
        conv_lines.append(f"{speaker}: {m['text']}")
    existing = json.dumps(row["target"]["suggestions"], ensure_ascii=False)
    system = (
        "Rewrite suggestions to sound more like natural text messages from a young person.\n"
        "Output one JSON object only: {\"suggestions\": [...]} with exactly same 3 labels.\n"
        "Keep stance and intent unchanged. Keep concise and sendable.\n"
        "Avoid assistant-like polish, therapy tone, corporate email wording, and cliche templates.\n"
        "No blind guessing: do not add new concrete specifics (time/place/reason) unless already in conversation.\n"
        "Do not use emoji. Do not use dash punctuation (- or —).\n"
        "For decisionReply, keep three responses rhythmically distinct and not same length.\n"
        "For replyStyles: shorten Thoughtful aggressively (<=18 words, one sentence, <=1 comma). "
        "Direct <=14 words, Friendly <=22. Cut reflection and tidy closure; keep a little rough.\n"
        "Each suggestion does ONE social move only; do not combine soothe + analyze + propose + outlook. "
        "Do not spell out subtext; do not explain more than needed; no high-EQ demo tone.\n"
        "For replyStyles: strip style-heavy slang from Direct and Thoughtful entirely; each may keep at most one ultra-light idk/rn/lmk. "
        "On Friendly, trim stacked style-heavy slang (cap ~2 style-heavy hits, <=3 total slang hits). Preserve warmth."
    )
    user = (
        f"Theme labels: {label_set}\n"
        f"Conversation:\n{'\n'.join(conv_lines)}\n\n"
        f"Current suggestions:\n{existing}\n\n"
        "Rewrite now."
    )
    last_err: str | None = None
    for attempt in range(max_retries):
        try:
            raw = call_claude_json(client, model, system, user, max_tokens=700, temperature=0.45)
            parsed = extract_json_object(raw)
            sug = parsed.get("suggestions")
            if not isinstance(sug, list) or len(sug) != 3:
                raise ValueError("depolish pass output missing 3 suggestions")
            out = dict(row)
            out["target"] = {"suggestions": sug}
            validate_record(out, infer_plan_from_row(out))
            return out
        except Exception as e:
            last_err = str(e)
            if attempt == max_retries - 1:
                raise RuntimeError(last_err) from e
            time.sleep(0.8 * (attempt + 1))
    raise RuntimeError(last_err or "depolish pass failed")


def generate_one_scene_input_only(
    client: Any,
    model: str,
    plan: dict[str, Any],
    sample_id: str,
    max_retries: int = 4,
) -> GenResult:
    idx = plan["index"]
    user_base = build_meta_input_user_prompt(plan)
    last_err = ""
    for attempt in range(max_retries):
        user = user_base
        if attempt > 0 and last_err:
            user += (
                "\n\nRetry correction: previous output failed validation. "
                f"Fix this error exactly: {last_err}. "
                "Keep all original plan constraints unchanged. Do not add target or suggestions."
            )
        try:
            raw = call_claude_json(client, model, META_INPUT_SYSTEM, user)
            parsed = extract_json_object(raw)
            row = merge_input_record(parsed, plan, sample_id)
            return GenResult(idx, True, row, None, None, True, None)
        except Exception as e:
            last_err = f"{type(e).__name__}: {e}"
            time.sleep(1.5 * (attempt + 1))
    return GenResult(idx, False, None, last_err, None, True, None)


def refine_suggestions_with_teacher(
    client: Any,
    model: str,
    row: dict[str, Any],
    user_profile: dict[str, Any] | None,
    max_retries: int = 4,
) -> dict[str, Any]:
    """Same system + user prompts as Reply Recommendation Demo teacher. Used for phase-2 targets only.

    Retries append the previous validation error to the user message. On the final attempt, if the model
    returns parseable ``suggestions`` (length 3) but ``validate_record`` still fails, the last candidate
    is returned anyway for downstream manual review.
    """
    system = build_teacher_system_param_blocks(row, user_profile, cache_ttl="1h")
    user_base = build_teacher_user_prompt(row)
    last_err: str | None = None
    for attempt in range(max_retries):
        user = user_base
        if attempt > 0 and last_err:
            user += (
                "\n\nRetry correction: previous output failed validation or parsing. "
                f"Fix this error exactly: {last_err}. "
                "Return only valid JSON with exactly 3 suggestions and the required labels for this task."
            )
        attempt_candidate: dict[str, Any] | None = None
        try:
            raw = call_claude_json(client, model, system, user, max_tokens=1024, temperature=0.65)
            parsed = extract_json_object(raw)
            sug = parsed.get("suggestions")
            if not isinstance(sug, list) or len(sug) != 3:
                raise ValueError("expected suggestions array of 3")
            attempt_candidate = dict(row)
            attempt_candidate["target"] = {"suggestions": sug}
            validate_record(attempt_candidate, infer_plan_from_row(attempt_candidate))
            return attempt_candidate
        except Exception as e:
            last_err = str(e)
            if attempt == max_retries - 1:
                if attempt_candidate is not None:
                    return attempt_candidate
                raise RuntimeError(last_err) from e
            time.sleep(1.0 * (attempt + 1))
    raise RuntimeError(last_err or "teacher pass failed")


def phase2_teacher_dict_to_gen_result(index: int, input_row: dict[str, Any], out: dict[str, Any]) -> GenResult:
    """Build phase-2 ``GenResult`` from a full teacher row (sync ``refine_suggestions_with_teacher`` output)."""
    line = {"sample_id": out["sample_id"], "suggestions": out["target"]["suggestions"]}
    try:
        validate_record(out, infer_plan_from_row(out))
        return GenResult(index, True, line, None, None, True, None)
    except Exception as e:
        return GenResult(index, True, line, None, None, False, f"{type(e).__name__}: {e}")


def build_teacher_batch_message_params(row: dict[str, Any], model: str) -> dict[str, Any]:
    """Params for one Messages API request inside a Message Batch (includes prompt-cached system)."""
    r = dict(row)
    return {
        "model": model,
        "max_tokens": 1024,
        "temperature": 0.65,
        "system": build_teacher_system_param_blocks(r, None, cache_ttl="1h"),
        "messages": [{"role": "user", "content": build_teacher_user_prompt(r)}],
    }


def teacher_response_text_to_gen_result(index: int, input_row: dict[str, Any], raw_text: str) -> GenResult:
    """Parse teacher JSON from batch output; keep 3-suggestion rows even when ``validate_record`` fails."""
    try:
        parsed = extract_json_object(raw_text)
        sug = parsed.get("suggestions")
        if not isinstance(sug, list) or len(sug) != 3:
            return GenResult(index, False, None, "expected suggestions array of 3", raw_text, True, None)
        out = dict(input_row)
        out["target"] = {"suggestions": sug}
        line = {"sample_id": out["sample_id"], "suggestions": out["target"]["suggestions"]}
        try:
            validate_record(out, infer_plan_from_row(out))
        except Exception as ve:
            return GenResult(
                index,
                True,
                line,
                None,
                raw_text,
                False,
                f"{type(ve).__name__}: {ve}",
            )
        return GenResult(index, True, line, None, None, True, None)
    except Exception as e:
        return GenResult(index, False, None, f"{type(e).__name__}: {e}", raw_text, True, None)
