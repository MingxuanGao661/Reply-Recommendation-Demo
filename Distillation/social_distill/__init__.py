"""
Social-reply distillation (Claude): plans, prompts, validation, two-phase JSONL output.

Entry point: ``python distillation/distill_claude_social_400.py`` (thin shim) or ``from social_distill.cli import main``.
"""

from .cli import main

__all__ = ["main"]
