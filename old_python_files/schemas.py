from __future__ import annotations
from dataclasses import dataclass, field, asdict
from typing import List, Optional
import json
import re


@dataclass
class Message:
    speaker: str
    text: str


@dataclass
class Profile:
    tone: str = "warm"
    length: str = "short"
    style: str = "casual"


@dataclass
class ConversationInput:
    conversation: List[Message]
    draft: str
    profile: Profile

    @classmethod
    def from_dict(cls, data: dict) -> "ConversationInput":
        messages = [Message(**m) for m in data["conversation"]]
        profile = Profile(**data.get("profile", {}))
        draft = data.get("draft", "") or ""
        return cls(conversation=messages, draft=draft.strip(), profile=profile)

    @classmethod
    def from_json(cls, json_str: str) -> "ConversationInput":
        return cls.from_dict(json.loads(json_str))

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class Suggestion:
    label: str
    text: str


@dataclass
class SuggestionOutput:
    suggestions: List[Suggestion]

    @classmethod
    def _parse_suggestions(cls, data: dict) -> List[Suggestion]:
        """Parse suggestions from various model output formats."""
        raw = data.get("suggestions", data)

        # Format A: [{"label": "...", "text": "..."}]  — expected
        if isinstance(raw, list):
            results = []
            for item in raw:
                if isinstance(item, dict) and "text" in item:
                    results.append(Suggestion(
                        label=item.get("label", f"Option {len(results)+1}"),
                        text=item["text"],
                    ))
                elif isinstance(item, dict):
                    key = next(iter(item))
                    results.append(Suggestion(label=key, text=str(item[key])))
                elif isinstance(item, str):
                    results.append(Suggestion(label=f"Option {len(results)+1}", text=item))
            return results

        # Format B: {"Natural": "...", "Polite": "...", "Like You": "..."}
        if isinstance(raw, dict):
            return [Suggestion(label=k, text=str(v)) for k, v in raw.items()
                    if isinstance(v, str)]

        return []

    @classmethod
    def from_dict(cls, data: dict) -> "SuggestionOutput":
        suggestions = cls._parse_suggestions(data)
        if not suggestions:
            return cls(suggestions=[Suggestion(label="Raw", text=str(data))])
        return cls(suggestions=suggestions)

    @classmethod
    def from_raw_text(cls, raw: str) -> "SuggestionOutput":
        """Parse model output, tolerant of markdown fences, garbage tails, and varied formats."""
        text = raw.strip()
        start = text.find("{")
        if start == -1:
            return cls(suggestions=[Suggestion(label="Raw", text=text)])

        # Try closing braces from right to left to find valid JSON
        search_from = len(text)
        while search_from > start:
            end = text.rfind("}", start, search_from)
            if end == -1:
                break
            try:
                data = json.loads(text[start:end + 1])
                return cls.from_dict(data)
            except (json.JSONDecodeError, KeyError, TypeError):
                search_from = end

        # Last resort: regex extraction of label/text pairs from malformed JSON
        pairs = re.findall(r'"label"\s*:\s*"([^"]+)"\s*,\s*"text"\s*:\s*"([^"]+)"', text)
        if pairs:
            return cls(suggestions=[Suggestion(label=l, text=t) for l, t in pairs])

        return cls(suggestions=[Suggestion(label="Raw", text=text)])

    def to_dict(self) -> dict:
        return asdict(self)

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent, ensure_ascii=False)


@dataclass
class EvalMetrics:
    model_name: str = ""
    latency_ms: float = 0.0
    memory_before_mb: float = 0.0
    memory_after_mb: float = 0.0
    memory_delta_mb: float = 0.0
    cpu_percent: float = 0.0
    tokens_generated: int = 0
    tokens_per_sec: float = 0.0
    prompt_tokens: int = 0
    total_tokens: int = 0

    def to_dict(self) -> dict:
        return asdict(self)

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent)

    def summary(self) -> str:
        lines = [
            f"Model:            {self.model_name}",
            f"Latency:          {self.latency_ms:.0f} ms",
            f"Memory delta:     {self.memory_delta_mb:+.1f} MB",
            f"CPU usage:        {self.cpu_percent:.1f}%",
        ]
        if self.tokens_generated > 0:
            lines.append(f"Tokens generated: {self.tokens_generated}")
            lines.append(f"Tokens/sec:       {self.tokens_per_sec:.1f}")
        if self.total_tokens > 0:
            lines.append(f"Total tokens:     {self.total_tokens}")
        return "\n".join(lines)
