#!/usr/bin/env python3
"""Split a JSONL into two halves (a = first ceil(n/2) lines, b = rest)."""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("input", type=Path, help="source .jsonl")
    p.add_argument("--a-out", type=Path, default=None, help="default: {stem}_a.jsonl next to input")
    p.add_argument("--b-out", type=Path, default=None, help="default: {stem}_b.jsonl next to input")
    args = p.parse_args()
    inp: Path = args.input
    lines = [ln for ln in inp.read_text(encoding="utf-8").splitlines() if ln.strip()]
    mid = (len(lines) + 1) // 2
    a_out = args.a_out or inp.with_name(inp.stem + "_a.jsonl")
    b_out = args.b_out or inp.with_name(inp.stem + "_b.jsonl")
    a_out.parent.mkdir(parents=True, exist_ok=True)
    b_out.parent.mkdir(parents=True, exist_ok=True)
    a_out.write_text("\n".join(lines[:mid]) + "\n", encoding="utf-8")
    b_out.write_text("\n".join(lines[mid:]) + "\n", encoding="utf-8")
    print(f"{inp}: {len(lines)} rows -> {a_out.name}: {mid}, {b_out.name}: {len(lines) - mid}")


if __name__ == "__main__":
    main()
