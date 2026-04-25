"""API key helpers, JSON extraction from model text, dotenv."""

from __future__ import annotations

import json
import re
from typing import Any

from .paths import REPO_ROOT


def normalize_api_key(raw: str | None) -> str:
    if not raw:
        return ""
    s = raw.strip().lstrip("\ufeff")
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        s = s[1:-1].strip()
    return s


def mask_api_key(key: str) -> str:
    if len(key) <= 14:
        return "(too short to mask)"
    return f"{key[:12]}…{key[-4:]} (len={len(key)})"


def extract_json_object(text: str) -> dict[str, Any]:
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```\s*$", "", text)
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError("No JSON object found in model output")
    return json.loads(text[start : end + 1])


def load_env_dotenv() -> None:
    try:
        from dotenv import load_dotenv

        load_dotenv(REPO_ROOT / ".env")
        load_dotenv()
    except ImportError:
        pass
