from __future__ import annotations
from dataclasses import dataclass, field, asdict
from enum import Enum
from typing import List, Optional
import json
import re


@dataclass
class Message:
    speaker: str
    text: str


@dataclass
class Profile:
    """App-aligned: optional tone/length per axis (see `Models.swift` / `Profile`)."""

    tone: Optional[str] = None
    length: Optional[str] = None
    # Legacy benchmark JSON only; ignored by prompts aligned with `PromptBuilder.swift`.
    style: Optional[str] = None

    @property
    def resolved_tone(self) -> str:
        return self.tone or "warm"

    @property
    def resolved_length(self) -> str:
        return self.length or "short"

    @staticmethod
    def merged_for_prompt(
        conversation: Optional["Profile"],
        user_default: Optional["Profile"],
    ) -> "Profile":
        c, u = conversation, user_default
        c_tone = c.tone if c else None
        c_len = c.length if c else None
        u_tone = u.tone if u else None
        u_len = u.length if u else None
        tone = c_tone if c_tone is not None else (u_tone if u_tone is not None else "warm")
        length = c_len if c_len is not None else (u_len if u_len is not None else "short")
        return Profile(tone=tone, length=length)


@dataclass
class Participant:
    id: str
    name: str
    is_self: Optional[bool] = None
    relationship: Optional[str] = None


class SuggestionThemeSet(Enum):
    """Mirrors `SuggestionThemeSet` in `Models.swift` (labels = Swift `labels`)."""

    REPLY_STYLES = ("Direct", "Friendly", "Thoughtful")
    DECISION_REPLY = ("Agree", "Soft Decline", "Delay")

    @property
    def labels(self) -> tuple[str, ...]:
        return self.value


def is_binary_decision_prompt(text: str) -> bool:
    """Port of `ConversationInput.isBinaryDecisionPrompt` in `Models.swift`."""
    normalized = " ".join(text.lower().replace("\n", " ").split())
    if not normalized:
        return False

    compact = " ".join(normalized.split())

    info_request_verbs = (
        "explain",
        "tell me",
        "tell us",
        "describe",
        "clarify",
        "help me",
        "help us",
        "show me",
        "show us",
        "give me",
        "give us",
        "let me know",
        "remind me",
        "remind us",
        "suggest",
        "recommend",
    )

    open_ended_prefixes = (
        "what",
        "when",
        "where",
        "why",
        "how",
        "which",
        "who",
    )
    yes_no_prefixes = (
        "are",
        "is",
        "am",
        "do",
        "does",
        "did",
        "can",
        "could",
        "would",
        "will",
        "should",
        "have",
        "has",
        "had",
        "may",
    )
    decision_phrases = (
        "want to",
        "do you want",
        "would you",
        "could you",
        "can you",
        "are you free",
        "are you available",
        "are you down",
        "still coming",
        "still down",
        "down to",
        "up for",
        "able to",
        "make it",
        "join us",
        "works for you",
        "does that work",
        "does that sound good",
        "is that okay",
        "okay with",
        "good with",
        "wanna",
        "u down",
        "u in",
        "u coming",
        "you coming",
        "you in",
        "you down",
        "you going",
        "u going",
        "tryna",
        "dtf",
        "you up",
        "u up",
        "coming with",
        "roll with",
        "game for",
        "down for",
        "in for",
        "still on",
        "still good",
        "cool with",
        "fine with",
    )

    if any(p in compact for p in decision_phrases):
        if " or " in compact and " or not" not in compact:
            return False
        if any(v in compact for v in info_request_verbs):
            return False
        return True

    first_token = (compact.split(" ")[0] if compact else "") or ""
    if first_token in open_ended_prefixes:
        return False

    if " or " in compact and " or not" not in compact:
        return False

    if "?" not in compact:
        return False

    if first_token in yes_no_prefixes:
        if any(v in compact for v in info_request_verbs):
            return False
        return True

    return False


@dataclass
class ConversationInput:
    conversation: List[Message]
    draft: str = ""
    """User default profile (app-wide). JSON key `profile` maps here."""
    profile: Profile = field(default_factory=Profile)
    conversation_profile: Optional[Profile] = None
    self_id: Optional[str] = None
    reply_to: Optional[str] = None
    participants: List[Participant] = field(default_factory=list)
    explicit_reply_target: Optional[Message] = None

    @property
    def resolved_self_id(self) -> str:
        return self.self_id or "me"

    @property
    def resolved_draft(self) -> str:
        return (self.draft or "").strip()

    @property
    def has_draft(self) -> bool:
        return bool(self.resolved_draft)

    @property
    def is_group_chat(self) -> bool:
        return len({m.speaker for m in self.conversation}) > 2

    def effective_profile(self, user_default: Optional[Profile] = None) -> Profile:
        u = user_default if user_default is not None else self.profile
        return Profile.merged_for_prompt(self.conversation_profile, u)

    def display_name(self, speaker_id: str) -> str:
        if speaker_id == self.resolved_self_id:
            return "Me"
        for p in self.participants:
            if p.id == speaker_id:
                return p.name
        return speaker_id

    @property
    def reply_target_name(self) -> Optional[str]:
        if not self.reply_to:
            return None
        return self.display_name(self.reply_to)

    @property
    def reply_target_message(self) -> Optional[Message]:
        if self.explicit_reply_target is not None:
            return self.explicit_reply_target
        if self.reply_to:
            for m in reversed(self.conversation):
                if m.speaker == self.reply_to:
                    return m
        return self.conversation[-1] if self.conversation else None

    def suggestion_theme_set(self) -> SuggestionThemeSet:
        if self.has_draft:
            return SuggestionThemeSet.REPLY_STYLES
        msg = self.reply_target_message
        text = msg.text if msg else ""
        if is_binary_decision_prompt(text):
            return SuggestionThemeSet.DECISION_REPLY
        return SuggestionThemeSet.REPLY_STYLES

    @classmethod
    def from_dict(cls, data: dict) -> "ConversationInput":
        messages = [Message(**m) for m in data["conversation"]]
        raw_profile = data.get("profile") or {}
        profile = Profile(
            tone=raw_profile.get("tone"),
            length=raw_profile.get("length"),
            style=raw_profile.get("style"),
        )
        if "conversation_profile" in data:
            cp = data["conversation_profile"] or {}
            conversation_profile = Profile(
                tone=cp.get("tone"),
                length=cp.get("length"),
                style=cp.get("style"),
            )
        else:
            conversation_profile = None
        draft = data.get("draft", "") or ""
        parts_raw = data.get("participants") or []
        participants: List[Participant] = []
        for p in parts_raw:
            participants.append(
                Participant(
                    id=p["id"],
                    name=p.get("name") or p["id"],
                    is_self=p.get("is_self", p.get("isSelf")),
                    relationship=p.get("relationship"),
                )
            )
        ert = data.get("explicit_reply_target")
        explicit_reply_target = Message(**ert) if ert else None
        return cls(
            conversation=messages,
            draft=draft.strip(),
            profile=profile,
            conversation_profile=conversation_profile,
            self_id=data.get("self_id"),
            reply_to=data.get("reply_to"),
            participants=participants,
            explicit_reply_target=explicit_reply_target,
        )

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
