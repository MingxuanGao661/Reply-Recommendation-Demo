#!/usr/bin/env python3
"""Build social_2000_passed.jsonl and social_2000_pending_manual_verification.jsonl (see module docstring)."""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path
from typing import Any


def _load_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument(
        "--version1-dir",
        type=Path,
        default=Path("out/version1"),
        help="directory with round12 merged, inputs, round3 merged, validation_relaxed",
    )
    p.add_argument(
        "--out-dir",
        type=Path,
        default=Path("out"),
        help="where to write social_2000_passed.jsonl and social_2000_pending_manual_verification.jsonl",
    )
    p.add_argument("--sample-n", type=int, default=400, help="random strict-pass rows to include in pending")
    p.add_argument("--seed", type=int, default=42, help="RNG seed for the random sample")
    args = p.parse_args()

    v1: Path = args.version1_dir
    out_dir: Path = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    inputs_path = v1 / "social_2000.inputs.jsonl"
    round12_targets = v1 / "social_2000.targets.round12_merged.jsonl"
    r3_merged_path = v1 / "social_2000_round3.merged.jsonl"
    r3_relaxed_path = v1 / "social_2000_round3.targets.validation_relaxed.jsonl"

    by_sid: dict[str, dict[str, Any]] = {}
    for r in _load_jsonl(inputs_path):
        by_sid[r["sample_id"]] = r

    # Round1+2 strict pass: targets-only merged + full input row
    round12_passed: list[dict[str, Any]] = []
    for t in _load_jsonl(round12_targets):
        sid = t["sample_id"]
        row = dict(by_sid[sid])
        row["target"] = {"suggestions": t["suggestions"]}
        round12_passed.append(row)

    relaxed_order: list[tuple[str, str]] = []
    relaxed_ids: set[str] = set()
    for r in _load_jsonl(r3_relaxed_path):
        sid = r["sample_id"]
        err = r.get("validation_error") or ""
        relaxed_ids.add(sid)
        relaxed_order.append((sid, err))

    r3_by_sid: dict[str, dict[str, Any]] = {}
    for r in _load_jsonl(r3_merged_path):
        r3_by_sid[r["sample_id"]] = r

    round3_strict: list[dict[str, Any]] = []
    for sid, row in r3_by_sid.items():
        if sid not in relaxed_ids:
            round3_strict.append(dict(row))

    # Dedupe by sample_id (round12 and round3 strict should be disjoint)
    seen: set[str] = set()
    passed: list[dict[str, Any]] = []
    for row in round12_passed + round3_strict:
        sid = row["sample_id"]
        if sid in seen:
            continue
        seen.add(sid)
        passed.append(row)

    passed_path = out_dir / "social_2000_passed.jsonl"
    with open(passed_path, "w", encoding="utf-8") as f:
        for row in passed:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    random.seed(args.seed)
    n = min(args.sample_n, len(passed))
    sampled = random.sample(passed, n) if n else []

    pending_rows: list[dict[str, Any]] = []
    for row in sampled:
        pending_rows.append(dict(row))

    for sid, validation_error in relaxed_order:
        base = dict(r3_by_sid[sid])
        base["validation_error"] = validation_error
        pending_rows.append(base)

    pending_path = out_dir / "social_2000_pending_manual_verification.jsonl"
    with open(pending_path, "w", encoding="utf-8") as f:
        for row in pending_rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    print(f"Wrote {passed_path} ({len(passed)} lines)")
    print(
        f"Wrote {pending_path} ({len(pending_rows)} lines: "
        f"{len(sampled)} random strict-pass + {len(relaxed_order)} round3 validation_relaxed)"
    )


if __name__ == "__main__":
    main()
