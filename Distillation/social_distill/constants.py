"""Prompt mirrors, word bounds, marker lists, and diversity tags for social distill."""

from __future__ import annotations

# Phase-1 input channel (each *.inputs.jsonl row carries ``input_provenance``).
INPUT_PROVENANCE_SYNTHETIC = "synthetic_input"
INPUT_PROVENANCE_HUMAN_SEEDED = "human_seeded_input"
INPUT_PROVENANCE_CHOICES = (INPUT_PROVENANCE_SYNTHETIC, INPUT_PROVENANCE_HUMAN_SEEDED)

THEME_RULES = {
    "replyStyles": (
        "- Three reply styles — all replying to the LAST message only; each must feel NOTICEABLY different:\n"
        "  • Direct    = lead with the answer right away; skip warm-ups and filler; shorter is better\n"
        "  • Friendly  = add one warm or personal touch; style-heavy slang (ngl, fr, tbh, lowkey, bet, …) can appear sparingly; "
        "Direct/Thoughtful: **no** style-heavy slang; at most **one** ultra-light abbreviation (idk, rn, lmk) if natural. Don't recap the conversation\n"
        "  • Thoughtful = ONE short beat: lightly echo the last message, then answer. Stay short (do NOT write a reflective mini essay). "
        "Do not sound like a therapist or relationship coach; no tidy moral or closure."
    ),
    "decisionReply": (
        "- Three decision stances — all replying to the LAST message; each must give a clearly different answer:\n"
        "  • Agree       = clear yes / direct acceptance; no hedging\n"
        "  • Soft Decline = kind no — warm but firm; don't over-explain\n"
        "  • Delay       = defer without committing — ask for more time or say you'll confirm later"
    ),
}

LABEL_LISTS = {
    "replyStyles": '"Direct", "Friendly", "Thoughtful"',
    "decisionReply": '"Agree", "Soft Decline", "Delay"',
}

QUALITY_CONSTRAINTS = """\
Additional quality constraints for all outputs:

- Write like a real young person in college texting, not like a polished assistant.
- Keep replies sendable. Do not optimize for being impressive.
- Avoid sounding overly emotionally intelligent, overly careful, or therapist-like.
- Avoid generic polished lines that could fit any context.
- Avoid over-explaining, over-validating, or wrapping a simple answer in too much softness.
- "Friendly" should feel warmer, not just noisier or more full of filler like "haha". **Style-heavy** slang (ngl, fr, tbh, lowkey, bet, …) belongs mainly on Friendly — use lightly, not stacked. **Direct/Thoughtful**: no style-heavy slang; at most **one** ultra-light abbreviation (idk, rn, lmk) per line when it fits.
- "Thoughtful" should feel slightly more context-aware, not longer, not more formal, and not a reflective paragraph.
- "Direct" should be concise and clear, but not cold or blunt unless the context truly calls for it.
- The three outputs must feel noticeably different in strategy, not just wording.
- One message, one move: do not stack multiple social jobs in a single reply.
- Never do all at once: reassurance + analysis + proposal + future outlook; pick one beat per line.
- Do not explain more than this thread actually requires.
- Do not spell out subtext or "read the room" out loud; leave some implicit.
- Never pad length to sound Thoughtful; Thoughtful is slightly more anchored, not longer.
- Do not sound like a polished "high-EQ example answer" or social-skills coaching script.
- Abbreviations and light youth/internet phrasing are fine when they fit the relationship and thread — keep it readable and sendable; do not pile on slang, forced letter-dropping, or a performative very-online voice. (replyStyles: **Friendly** may use style-heavy markers sparingly; **Direct/Thoughtful** only ultra-light idk/rn/lmk, at most one each; **decisionReply** keep readable, no style-heavy pile-on.)
- Avoid canned polite templates like "I'd love to", "Looking forward to it", "Sorry to miss it", "double-check my calendar", "by end of day", "at your earliest convenience".
- Avoid email/HR phrasing. Keep it spoken-text natural, not corporate polished.
- For decisionReply: keep outputs short and asymmetric in rhythm; do not make all three the same sentence length/style.
- For replyStyles: do not pack attitude + long explanation + boundary + next step into one message. Often one clause is enough; two short clauses max for Friendly only.
- For replyStyles Thoughtful: max ~18 words, at most one comma, single sentence (no period then more text). Stop early; sounding \"done\" and a little rough is better than polished closure.
- Do not use emoji in suggestions.
- Do not use hyphen/dash punctuation in suggestions (avoid both "-" and "—").
- Prefer natural brevity. If one sentence works, do not make it three."""

SCENE_TAGS = ("awkward", "soft_interest", "delay", "reconnect", "casual_warmth")
SOCIAL_RISK = ("low", "medium", "high")
RELATIONSHIP_DISTANCE = ("close", "medium", "distant")

DEFAULT_MODEL = "claude-sonnet-4-6"

ANTI_CLICHE_PHRASES = (
    "looking forward to it",
    "sorry to miss it",
    "double-check my calendar",
    "by end of day",
    "absolutely count me in",
    "count me in, and thanks so much",
    "no pressure at all",
    "i genuinely appreciate",
    "thank you for understanding",
    "i hope that makes sense",
    "i appreciate your understanding",
    "at your earliest convenience",
    "i apologize for any inconvenience",
)

OVERPOLITE_PHRASES = (
    "absolutely",
    "genuinely",
    "appreciate your understanding",
    "thank you for your understanding",
    "at your earliest convenience",
    "i apologize",
    "sincerely",
)

DECISION_WORD_BOUNDS = {
    "Agree": (2, 18),
    "Soft Decline": (5, 24),
    "Delay": (5, 22),
}

REPLY_STYLE_WORD_MAX = {
    "Direct": 22,
    "Friendly": 28,
    "Thoughtful": 24,
}

STYLE_HEAVY_MARKERS = (
    "ngl",
    "tbh",
    "fr",
    "frfr",
    "lowkey",
    "highkey",
    "bet",
    "omw",
    "wyd",
    "hmu",
    "idek",
    "nvm",
    "irl",
)

ULTRA_LIGHT_MARKERS = ("idk", "rn", "lmk")

FILLER_TOKENS = frozenset(
    {"haha", "lol", "lmao", "lmfao", "hehe", "um", "uh", "like", "yeah", "yep", "ok", "okay", "so", "tbh"}
)

SUGGESTION_PAIRWISE_SIMILARITY_MAX = 0.93
FIRST_CLAUSE_SIMILARITY_MAX = 0.96

THERAPIST_LIKE_PHRASES = (
    "i promise",
    "it was actually really",
    "sometimes you just",
    "until you actually",
    "how easy it is",
    "at the end of the day",
    "i hear you",
    "i totally get",
    "holding space",
    "processed",
    "proud of you",
    "take care of yourself",
    "i'm here for you",
    "im here for you",
    "really nice to reconnect",
    "forget how",
)

DETAIL_MARKER_WORDS = (
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "friday",
    "saturday",
    "sunday",
    "today",
    "tonight",
    "tomorrow",
    "weekend",
    "morning",
    "afternoon",
    "evening",
    "lunch",
    "dinner",
    "cafe",
    "coffee",
    "restaurant",
    "office",
    "campus",
    "downtown",
    "station",
    "airport",
    "room",
    "building",
    "street",
    "address",
)
