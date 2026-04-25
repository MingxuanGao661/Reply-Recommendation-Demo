"""Normalization, slang/similarity checks, detail markers, replyStyles tightening."""

from __future__ import annotations

import difflib
import re
from typing import Any

from .constants import (
    ANTI_CLICHE_PHRASES,
    DECISION_WORD_BOUNDS,
    DETAIL_MARKER_WORDS,
    FILLER_TOKENS,
    FIRST_CLAUSE_SIMILARITY_MAX,
    OVERPOLITE_PHRASES,
    REPLY_STYLE_WORD_MAX,
    STYLE_HEAVY_MARKERS,
    SUGGESTION_PAIRWISE_SIMILARITY_MAX,
    THERAPIST_LIKE_PHRASES,
    ULTRA_LIGHT_MARKERS,
)


def normalize_text(s: str) -> str:
    return re.sub(r"\s+", " ", s.strip().lower())


def contains_any_phrase(text: str, phrases: tuple[str, ...]) -> str | None:
    t = normalize_text(text)
    for p in phrases:
        if p in t:
            return p
    return None


def extract_detail_markers(text: str) -> set[str]:
    t = normalize_text(text)
    markers: set[str] = set()
    for m in re.findall(r"\b\d{1,2}(?::\d{2})?\s?(?:am|pm)?\b", t):
        markers.add(m.replace(" ", ""))
    for w in DETAIL_MARKER_WORDS:
        if re.search(rf"\b{re.escape(w)}\b", t):
            markers.add(w)
    return markers


def detail_budget_for_risk(social_risk: str | None) -> int:
    if social_risk == "high":
        return 2
    if social_risk == "medium":
        return 3
    return 4


def marker_hit_count(text: str, words: tuple[str, ...]) -> int:
    t = normalize_text(text)
    return sum(len(re.findall(rf"\b{re.escape(w)}\b", t)) for w in words)


def style_heavy_count(text: str) -> int:
    n = marker_hit_count(text, STYLE_HEAVY_MARKERS)
    if "no cap" in normalize_text(text):
        n += 1
    return n


def ultra_light_count(text: str) -> int:
    return marker_hit_count(text, ULTRA_LIGHT_MARKERS)


def friendly_has_any_slang(text: str) -> bool:
    return style_heavy_count(text) > 0 or ultra_light_count(text) > 0


def strip_for_similarity(text: str) -> str:
    t = text.lower()
    t = re.sub(r"[^\w\s]", " ", t)
    t = re.sub(r"\s+", " ", t).strip()
    toks = [x for x in t.split() if x not in FILLER_TOKENS]
    return " ".join(toks)


def first_clause_stripped(text: str) -> str:
    t = text.strip()
    for sep in (",", ".", "!", "?"):
        if sep in t:
            t = t.split(sep, 1)[0]
            break
    return strip_for_similarity(t)


def max_pairwise_similarity(tri: tuple[str, str, str]) -> float:
    a, b, c = tri
    sa, sb, sc = strip_for_similarity(a), strip_for_similarity(b), strip_for_similarity(c)
    if not sa or not sb or not sc:
        return 0.0
    return max(
        difflib.SequenceMatcher(None, sa, sb).ratio(),
        difflib.SequenceMatcher(None, sa, sc).ratio(),
        difflib.SequenceMatcher(None, sb, sc).ratio(),
    )


def validate_suggestion_strategy_distinct(theme: str, text_by_label: dict[str, str]) -> None:
    if theme == "replyStyles":
        tri = (
            text_by_label["Direct"],
            text_by_label["Friendly"],
            text_by_label["Thoughtful"],
        )
        mp = max_pairwise_similarity(tri)
        if mp >= SUGGESTION_PAIRWISE_SIMILARITY_MAX:
            raise ValueError(f"suggestions too similar pairwise (max ratio {mp:.2f})")
        dfc = first_clause_stripped(text_by_label["Direct"])
        ffc = first_clause_stripped(text_by_label["Friendly"])
        tfc = first_clause_stripped(text_by_label["Thoughtful"])
        if min(len(dfc), len(ffc), len(tfc)) >= 4:
            rdf = difflib.SequenceMatcher(None, dfc, ffc).ratio()
            rdt = difflib.SequenceMatcher(None, dfc, tfc).ratio()
            rft = difflib.SequenceMatcher(None, ffc, tfc).ratio()
            if max(rdf, rdt, rft) >= FIRST_CLAUSE_SIMILARITY_MAX:
                raise ValueError("replyStyles first clauses too similar (strategy not distinct)")
    elif theme == "decisionReply":
        tri = (
            text_by_label["Agree"],
            text_by_label["Soft Decline"],
            text_by_label["Delay"],
        )
        mp = max_pairwise_similarity(tri)
        if mp >= SUGGESTION_PAIRWISE_SIMILARITY_MAX:
            raise ValueError(f"suggestions too similar pairwise (max ratio {mp:.2f})")


def validate_reply_styles_suggestions(text_by_label: dict[str, str], word_count_by_label: dict[str, int]) -> None:
    for label, mx in REPLY_STYLE_WORD_MAX.items():
        wc = word_count_by_label.get(label, 0)
        if wc > mx:
            raise ValueError(f"{label} too long: {wc} words (max {mx})")
    th = text_by_label.get("Thoughtful", "")
    t = normalize_text(th)
    for phrase in THERAPIST_LIKE_PHRASES:
        if phrase in t:
            raise ValueError(f'Thoughtful therapist-like phrase: "{phrase}"')
    if th.count(",") > 2:
        raise ValueError("Thoughtful: at most two commas")
    if len(re.findall(r"\band\b", t)) > 1:
        raise ValueError("Thoughtful: at most one coordinating 'and'")
    if re.search(r"\.\s+[A-Za-z]", th):
        raise ValueError("Thoughtful: single sentence only (no text after a period)")
    d_txt = text_by_label.get("Direct", "")
    f_txt = text_by_label.get("Friendly", "")
    if style_heavy_count(d_txt) > 0:
        raise ValueError("Direct: no style-heavy slang (ngl/fr/lowkey/bet/...)")
    if ultra_light_count(d_txt) > 2:
        raise ValueError("Direct: at most two ultra-light markers (idk, rn, lmk)")
    th_txt = text_by_label.get("Thoughtful", "")
    if style_heavy_count(th_txt) > 0:
        raise ValueError("Thoughtful: no style-heavy slang")
    if ultra_light_count(th_txt) > 2:
        raise ValueError("Thoughtful: at most two ultra-light markers (idk, rn, lmk)")
    if style_heavy_count(f_txt) > 3:
        raise ValueError("Friendly: at most three style-heavy slang hits")
    if style_heavy_count(f_txt) + ultra_light_count(f_txt) > 4:
        raise ValueError("Friendly: too many slang markers total")
