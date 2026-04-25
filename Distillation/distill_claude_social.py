#!/usr/bin/env python3
"""
Distill social-reply data with Claude Sonnet 4.6 in **two files** (Reply Recommendation Demo shape):

1. **Inputs** (`*.inputs.jsonl`) — scene only: `conversation`, `participants`, `reply_to`, `conversation_profile`,
   `draft`, `self_id`, plus curriculum keys `sample_id`, `task_type`, `suggestion_theme`, `distillation_controls`, `metadata`,
   and ``input_provenance`` (`synthetic_input` from Claude, or ``human_seeded_input`` from ``--human-seeded-inputs``).
   No `target` / no suggestions (matches demo **ConversationInput** fields + training metadata).

2. **Targets** (`*.targets.jsonl`) — one JSON object per line: `sample_id` + **SuggestionOutput** shape
   `{"suggestions": [{"label","text"}, x3]}` exactly as `Reply Recommendation Demo/Backend/Models.swift`.

Teacher pass (same prompts as the demo teacher) generates targets with retries; **depolish is not part of the default pipeline**
(use `depolish-screen` for optional human screening).

Implementation lives in ``distillation/social_distill/`` (constants, prompts, plans, validation, generation, CLI).

Requires: pip install anthropic python-dotenv
Env: ANTHROPIC_API_KEY — set in the shell or in repo-root `.env`.

Usage:
  python distillation/distill_claude_social.py --out distillation/out/social_400.jsonl
  python distillation/distill_claude_social.py --inputs-out distillation/out/social.inputs.jsonl \\
      --targets-out distillation/out/social.targets.jsonl
  python distillation/distill_claude_social.py --total 400 --limit 5 --dry-run
  python distillation/distill_claude_social.py --input-provenance human_seeded_input \\
      --human-seeded-inputs path/to/rows.jsonl --out distillation/out/social_400.jsonl
  python distillation/distill_claude_social.py depolish-screen --depolish-in merged.jsonl --depolish-out screen.jsonl
"""

from __future__ import annotations

from social_distill.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
