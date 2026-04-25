"""Allow: ``cd distillation && python -m social_distill --help`` (same as ``distill_claude_social_400.py``)."""

from .cli import main

if __name__ == "__main__":
    raise SystemExit(main())
