"""Argument parsing and two-phase + depolish-screen orchestration."""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any, Optional

from .constants import (
    DEFAULT_MODEL,
    INPUT_PROVENANCE_CHOICES,
    INPUT_PROVENANCE_HUMAN_SEEDED,
    INPUT_PROVENANCE_SYNTHETIC,
)
from .batch_phase2 import run_phase2_teacher_batches
from .generation import (
    GenResult,
    depolish_suggestions,
    generate_one_scene_input_only,
    phase2_teacher_dict_to_gen_result,
    refine_suggestions_with_teacher,
)
from .plans import build_scene_plans
from .records import ingest_human_seeded_input_row
from .stats_summary import build_run_summary, failure_bucket, record_row_into_stats, suggestions_json
from .utils import load_env_dotenv, mask_api_key, normalize_api_key


def _try_tqdm(total: int, desc: str, *, enabled: bool):
    """Return a tqdm instance, or None if disabled / missing / total<=0."""
    if not enabled or total <= 0:
        return None
    try:
        from tqdm import tqdm

        return tqdm(
            total=total,
            desc=desc,
            unit="row",
            mininterval=0.2,
            file=sys.stderr,
            dynamic_ncols=True,
        )
    except ImportError:
        return None


def cmd_depolish_screen(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="distill_claude_social_400.py depolish-screen")
    p.add_argument("--depolish-in", type=Path, required=True, help="JSONL with full rows including target")
    p.add_argument("--depolish-out", type=Path, required=True, help="JSONL screening records (before/after)")
    p.add_argument("--model", default=os.environ.get("ANTHROPIC_MODEL", DEFAULT_MODEL))
    p.add_argument("--workers", type=int, default=2, help="parallel rows (default 2)")
    args = p.parse_args(argv)
    load_env_dotenv()
    api_key = normalize_api_key(os.environ.get("ANTHROPIC_API_KEY"))
    if not api_key:
        print("Missing ANTHROPIC_API_KEY", file=sys.stderr)
        return 1
    import anthropic

    client = anthropic.Anthropic(api_key=api_key)
    args.depolish_out.parent.mkdir(parents=True, exist_ok=True)
    lines_in = args.depolish_in.read_text(encoding="utf-8").splitlines()
    rows: list[dict[str, Any]] = []
    for line in lines_in:
        line = line.strip()
        if not line:
            continue
        rows.append(json.loads(line))

    def work(item: tuple[int, dict[str, Any]]) -> tuple[int, dict[str, Any]]:
        j, row = item
        sid = row.get("sample_id", f"row_{j}")
        tgt = row.get("target") or {}
        sug = tgt.get("suggestions")
        if not isinstance(sug, list) or len(sug) != 3:
            return (
                j,
                {"sample_id": sid, "skipped": True, "reason": "missing or invalid target.suggestions"},
            )
        before = json.loads(json.dumps(sug, ensure_ascii=False))
        try:
            polished = depolish_suggestions(client, args.model, row)
            after = polished["target"]["suggestions"]
            changed = suggestions_json(before) != suggestions_json(after)
            return (
                j,
                {
                    "sample_id": sid,
                    "changed": changed,
                    "before": before,
                    "after": after,
                    "error": None,
                },
            )
        except Exception as e:
            return (
                j,
                {
                    "sample_id": sid,
                    "changed": False,
                    "before": before,
                    "after": None,
                    "error": f"{type(e).__name__}: {e}",
                },
            )

    out_lines: list[str | None] = [None] * len(rows)
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as ex:
        done = 0
        futs = {ex.submit(work, (j, row)): j for j, row in enumerate(rows)}
        for fut in as_completed(futs):
            j, payload = fut.result()
            out_lines[j] = json.dumps(payload, ensure_ascii=False)
            done += 1
            if done % 10 == 0 or done == len(rows):
                print(f"depolish-screen progress {done}/{len(rows)}")
    args.depolish_out.write_text("\n".join(x for x in out_lines if x is not None) + "\n", encoding="utf-8")
    print(f"Wrote depolish screening -> {args.depolish_out}")
    return 0


def cmd_distill(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Two-phase distill: demo-shaped inputs + SuggestionOutput targets")
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="optional basename: writes {stem}.inputs.jsonl and {stem}.targets.jsonl next to this path's parent "
        "(if path ends in .jsonl, stem is used without that suffix). Ignored if --inputs-out/--targets-out are set.",
    )
    parser.add_argument(
        "--inputs-out",
        type=Path,
        default=None,
        help="phase 1: conversation rows (no target); default distillation/out/social_400.inputs.jsonl or derived from --out",
    )
    parser.add_argument(
        "--targets-out",
        type=Path,
        default=None,
        help="phase 2: SuggestionOutput-shaped JSON per line (+ sample_id); default sibling of --inputs-out",
    )
    parser.add_argument(
        "--merged-out",
        type=Path,
        default=None,
        help="optional: full training rows (input fields + target) for convenience",
    )
    parser.add_argument(
        "--input-provenance",
        dest="input_provenance",
        choices=INPUT_PROVENANCE_CHOICES,
        default=INPUT_PROVENANCE_SYNTHETIC,
        help="phase 1: synthetic_input (Claude) or human_seeded_input (curator JSONL; see --human-seeded-inputs)",
    )
    parser.add_argument(
        "--human-seeded-inputs",
        type=Path,
        default=None,
        help="when --input-provenance human_seeded_input: JSONL, one object per line in the same order as .plans.json",
    )
    parser.add_argument("--model", default=os.environ.get("ANTHROPIC_MODEL", DEFAULT_MODEL))
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument(
        "--total",
        type=int,
        default=400,
        help="number of diversity plans to build (build_scene_plans n); default 400",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="cap rows to generate from that pool (default: same as --total)",
    )
    parser.add_argument(
        "--teacher-retries",
        type=int,
        default=4,
        help="per-row teacher attempts (default 4); each retry sees the last validation error. "
        "On the final attempt, if JSON has 3 suggestions but validation still fails, the last candidate is kept for manual review.",
    )
    parser.add_argument(
        "--phase2-message-batch",
        action="store_true",
        help="Phase 2: use Anthropic Message Batches (lower token price, async; can take up to ~24h). "
        "Uses prompt-cached shared quality block. Rows that fail API/JSON parsing go to failures log + "
        "*.batch_failures.jsonl. Rows with parseable 3 suggestions but failed local validation are still "
        "written to *.targets.jsonl (same shape as strict passes) and listed in *.validation_relaxed.jsonl; "
        "use --phase2-batch-rescue to retry hard failures with sync teacher.",
    )
    parser.add_argument(
        "--phase2-batch-rescue",
        action="store_true",
        help="With --phase2-message-batch: after each chunk, retry failed rows via sync refine_suggestions_with_teacher (full price).",
    )
    parser.add_argument(
        "--phase2-batch-chunk-size",
        type=int,
        default=200,
        metavar="N",
        help="with --phase2-message-batch: max requests per batch job (default 200; lower if the API rejects payload size)",
    )
    parser.add_argument(
        "--phase2-batch-poll-seconds",
        type=int,
        default=30,
        metavar="S",
        help="with --phase2-message-batch: seconds between status polls while a batch runs (default 30)",
    )
    parser.add_argument(
        "--phase2-resume",
        action="store_true",
        help="Phase 2: skip sample_ids already present in targets JSONL; append new lines to the targets file",
    )
    parser.add_argument(
        "--skip-phase-1",
        action="store_true",
        help="Skip Phase 1 API; use existing --inputs-out JSONL (must exist). Only with synthetic_input provenance.",
    )
    parser.add_argument("--dry-run", action="store_true", help="only write scene plans, no API")
    parser.add_argument(
        "--no-progress-bar",
        action="store_true",
        help="disable tqdm bar; print plain progress every --progress-log-interval rows instead",
    )
    parser.add_argument(
        "--progress-log-interval",
        type=int,
        default=10,
        metavar="N",
        help="when progress bar is off, print Phase 1/2 progress every N completed rows (default 10)",
    )
    args = parser.parse_args(argv)
    if args.out is not None:
        base = args.out
        stem = base.stem if base.suffix == ".jsonl" else base.name
        parent = base.parent
        if args.inputs_out is None:
            args.inputs_out = parent / f"{stem}.inputs.jsonl"
        if args.targets_out is None:
            args.targets_out = parent / f"{stem}.targets.jsonl"
    if args.inputs_out is None:
        args.inputs_out = Path("distillation/out/social_400.inputs.jsonl")
    if args.targets_out is None:
        args.targets_out = args.inputs_out.with_name(
            args.inputs_out.stem.replace(".inputs", ".targets") + ".jsonl"
        )
    limit_rows = args.limit if args.limit is not None else args.total
    if args.total < 1:
        print("ERROR: --total must be >= 1", file=sys.stderr)
        return 2
    if limit_rows < 1:
        print("ERROR: --limit must be >= 1", file=sys.stderr)
        return 2
    if args.progress_log_interval < 1:
        print("ERROR: --progress-log-interval must be >= 1", file=sys.stderr)
        return 2
    progress_log_interval = args.progress_log_interval
    use_pbar = not args.no_progress_bar

    if args.skip_phase_1 and args.input_provenance != INPUT_PROVENANCE_SYNTHETIC:
        print("ERROR: --skip-phase-1 only supports --input-provenance synthetic_input", file=sys.stderr)
        return 2

    if args.input_provenance == INPUT_PROVENANCE_HUMAN_SEEDED and not args.dry_run:
        if args.human_seeded_inputs is None:
            print(
                "ERROR: --human-seeded-inputs is required when --input-provenance human_seeded_input",
                file=sys.stderr,
            )
            return 2
        if not args.human_seeded_inputs.is_file():
            print(f"ERROR: --human-seeded-inputs is not a file: {args.human_seeded_inputs}", file=sys.stderr)
            return 2

    load_env_dotenv()

    plans = build_scene_plans(args.total, seed=args.seed)[:limit_rows]
    for p in plans:
        p["input_provenance"] = args.input_provenance
    args.inputs_out.parent.mkdir(parents=True, exist_ok=True)
    plan_path = args.inputs_out.with_suffix(".plans.json")
    plan_path.write_text(json.dumps(plans, indent=2), encoding="utf-8")
    print(f"Wrote diversity plans ({len(plans)} rows) -> {plan_path}")

    if args.dry_run:
        print("Dry run: skipping API.")
        return 0

    write_lock = threading.Lock()
    fail_inputs = args.inputs_out.with_name(args.inputs_out.stem + ".failures.log")
    fail_targets = args.targets_out.with_name(args.targets_out.stem + ".failures.log")
    stats: dict[str, Any] = {
        "n_written": 0,
        "by_task": Counter(),
        "by_theme": Counter(),
        "by_relationship": Counter(),
        "by_tone": Counter(),
        "by_length": Counter(),
        "word_sum": defaultdict(int),
        "word_n": defaultdict(int),
        "replystyles_rows": 0,
        "thoughtful_gt18": 0,
        "friendly_slang": 0,
        "teacher_pass_invoked": 0,
        "teacher_pass_fallback": 0,
        "failure_buckets": Counter(),
        "targets_validation_relaxed": 0,
        "phase1_ok": 0,
        "phase1_plans": len(plans),
        "phase1_by_provenance": Counter(),
        "by_input_provenance": Counter(),
    }

    client: Optional[Any] = None

    if args.skip_phase_1:
        if not args.inputs_out.is_file():
            print(f"ERROR: --skip-phase-1 requires an existing inputs file: {args.inputs_out}", file=sys.stderr)
            return 2
        ok_p1 = sum(1 for ln in args.inputs_out.read_text(encoding="utf-8").splitlines() if ln.strip())
        stats["phase1_ok"] = ok_p1
        stats["phase1_by_provenance"][INPUT_PROVENANCE_SYNTHETIC] = ok_p1
        print(f"Phase 1 skipped (--skip-phase-1). Loaded count={ok_p1} from {args.inputs_out}")
    elif args.input_provenance == INPUT_PROVENANCE_HUMAN_SEEDED:
        raw_lines = args.human_seeded_inputs.read_text(encoding="utf-8").splitlines()
        human_rows = [json.loads(l) for l in raw_lines if l.strip()]
        if len(human_rows) != len(plans):
            print(
                f"ERROR: human_seeded JSONL has {len(human_rows)} rows but plan has {len(plans)} slots "
                "(line order must match plan index order).",
                file=sys.stderr,
            )
            return 2
        print(f"Phase 1: ingesting {len(plans)} human_seeded_input rows -> {args.inputs_out}")
        p1_bar = _try_tqdm(len(plans), "phase1 human", enabled=use_pbar)
        try:
            with open(args.inputs_out, "w", encoding="utf-8") as finp, open(fail_inputs, "a", encoding="utf-8") as flog:
                done_h = 0
                for plan in plans:
                    sid = f"social_{plan['index']:06d}"
                    try:
                        row = ingest_human_seeded_input_row(human_rows[plan["index"]], plan, sid)
                        finp.write(json.dumps(row, ensure_ascii=False) + "\n")
                        finp.flush()
                        stats["phase1_ok"] += 1
                        stats["phase1_by_provenance"][INPUT_PROVENANCE_HUMAN_SEEDED] += 1
                    except Exception as e:
                        flog.write(f"index {plan['index']}: {type(e).__name__}: {e}\n")
                        flog.flush()
                        stats["failure_buckets"][f"phase1:{failure_bucket(str(e))}"] += 1
                    done_h += 1
                    if p1_bar:
                        p1_bar.update(1)
                    elif done_h % progress_log_interval == 0 or done_h == len(plans):
                        print(f"  Phase 1 progress {done_h}/{len(plans)}")
        finally:
            if p1_bar:
                p1_bar.close()
        ok_p1 = stats["phase1_ok"]
        print(f"Phase 1 done. inputs_ok={ok_p1}/{len(plans)}")
    else:
        api_key = normalize_api_key(os.environ.get("ANTHROPIC_API_KEY"))
        if not api_key:
            print(
                "Missing ANTHROPIC_API_KEY — set in shell or repo-root `.env` as ANTHROPIC_API_KEY=sk-ant-...",
                file=sys.stderr,
            )
            return 1
        if not api_key.startswith("sk-ant-"):
            print(
                f"Warning: key does not start with sk-ant- (loaded as {mask_api_key(api_key)}). "
                "Anthropic console keys normally look like sk-ant-api03-...",
                file=sys.stderr,
            )
        else:
            print(f"Using ANTHROPIC_API_KEY {mask_api_key(api_key)}")

        import anthropic

        client = anthropic.Anthropic(api_key=api_key)

        def job_phase1(plan: dict[str, Any]) -> GenResult:
            sid = f"social_{plan['index']:06d}"
            return generate_one_scene_input_only(client, args.model, plan, sid)

        results_p1: list[GenResult | None] = [None] * len(plans)
        print(f"Phase 1: generating {len(plans)} synthetic_input rows (no target) -> {args.inputs_out}")
        p1_bar = _try_tqdm(len(plans), "phase1 synth", enabled=use_pbar)
        try:
            with open(args.inputs_out, "w", encoding="utf-8") as finp, open(fail_inputs, "a", encoding="utf-8") as flog:
                with ThreadPoolExecutor(max_workers=max(1, args.workers)) as ex:
                    futs = {ex.submit(job_phase1, p): p for p in plans}
                    done = 0
                    for fut in as_completed(futs):
                        plan = futs[fut]
                        try:
                            res = fut.result()
                        except Exception as e:
                            res = GenResult(plan["index"], False, None, str(e))
                        results_p1[res.index] = res
                        done += 1
                        if res.ok and res.row:
                            with write_lock:
                                finp.write(json.dumps(res.row, ensure_ascii=False) + "\n")
                                finp.flush()
                                stats["phase1_ok"] += 1
                                stats["phase1_by_provenance"][INPUT_PROVENANCE_SYNTHETIC] += 1
                        else:
                            with write_lock:
                                flog.write(f"index {res.index}: {res.error}\n")
                                flog.flush()
                                stats["failure_buckets"][f"phase1:{failure_bucket(res.error)}"] += 1
                        if p1_bar:
                            p1_bar.update(1)
                        elif done % progress_log_interval == 0 or done == len(plans):
                            print(f"  Phase 1 progress {done}/{len(plans)}")
        finally:
            if p1_bar:
                p1_bar.close()

        ok_p1 = sum(1 for r in results_p1 if r and r.ok)
        print(f"Phase 1 done. inputs_ok={ok_p1}/{len(plans)}")

    if client is None:
        api_key = normalize_api_key(os.environ.get("ANTHROPIC_API_KEY"))
        if not api_key:
            print(
                "Missing ANTHROPIC_API_KEY — set in shell or repo-root `.env` as ANTHROPIC_API_KEY=sk-ant-...",
                file=sys.stderr,
            )
            return 1
        if not api_key.startswith("sk-ant-"):
            print(
                f"Warning: key does not start with sk-ant- (loaded as {mask_api_key(api_key)}). "
                "Anthropic console keys normally look like sk-ant-api03-...",
                file=sys.stderr,
            )
        else:
            print(f"Using ANTHROPIC_API_KEY {mask_api_key(api_key)} (phase 2)")
        import anthropic

        client = anthropic.Anthropic(api_key=api_key)

    input_rows: list[dict[str, Any]] = []
    with open(args.inputs_out, encoding="utf-8") as finp:
        for line in finp:
            line = line.strip()
            if line:
                input_rows.append(json.loads(line))

    if not input_rows:
        print("No input rows written; skipping phase 2.", file=sys.stderr)
        stats["targets_ok"] = 0
        summary_path = args.targets_out.with_name(args.targets_out.stem + ".summary.json")
        summary = build_run_summary(stats, len(plans), ok_p1, args)
        summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"Quality summary -> {summary_path}")
        return 1

    results_p2: list[GenResult | None] = [None] * len(input_rows)
    existing_targets_by_sid: dict[str, dict[str, Any]] = {}
    if args.phase2_resume and args.targets_out.is_file():
        for raw_line in args.targets_out.read_text(encoding="utf-8").splitlines():
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                obj = json.loads(raw_line)
                sid = obj.get("sample_id")
                if sid and isinstance(obj.get("suggestions"), list):
                    existing_targets_by_sid[sid] = {"sample_id": sid, "suggestions": obj["suggestions"]}
            except json.JSONDecodeError:
                continue
    for i, row in enumerate(input_rows):
        sid = row.get("sample_id")
        if sid in existing_targets_by_sid:
            results_p2[i] = GenResult(i, True, existing_targets_by_sid[sid], None)
    indexed = [(i, r) for i, r in enumerate(input_rows) if results_p2[i] is None]

    for i, row in enumerate(input_rows):
        r = results_p2[i]
        if r and r.ok and r.row:
            merged_pre = dict(row)
            merged_pre["target"] = {"suggestions": r.row["suggestions"]}
            record_row_into_stats(merged_pre, stats)

    def job_phase2(pair: tuple[int, dict[str, Any]]) -> GenResult:
        i, input_row = pair
        try:
            out = refine_suggestions_with_teacher(
                client,
                args.model,
                dict(input_row),
                None,
                max_retries=args.teacher_retries,
            )
            return phase2_teacher_dict_to_gen_result(i, input_row, out)
        except Exception as e:
            return GenResult(i, False, None, f"{type(e).__name__}: {e}")

    merged_append = bool(
        args.merged_out and args.phase2_resume and args.merged_out.exists() and args.merged_out.stat().st_size > 0
    )
    merged_fout = (
        open(args.merged_out, "a" if merged_append else "w", encoding="utf-8")
        if args.merged_out
        else None
    )
    targets_append = bool(
        args.phase2_resume and args.targets_out.exists() and args.targets_out.stat().st_size > 0
    )
    targets_mode = "a" if targets_append else "w"
    val_relaxed_path = args.targets_out.with_name(args.targets_out.stem + ".validation_relaxed.jsonl")
    val_relaxed_append = bool(
        args.phase2_resume and val_relaxed_path.is_file() and val_relaxed_path.stat().st_size > 0
    )
    val_relaxed_mode = "a" if val_relaxed_append else "w"
    skipped_targets = len(input_rows) - len(indexed)
    p2_label = "phase2 teacher"
    phase2_extra = ""
    if args.phase2_message_batch:
        p2_label = "phase2 teacher (batch)"
        phase2_extra = " [Message Batches + prompt cache]"
    print(
        f"Phase 2: teacher targets for {len(indexed)} rows"
        + (f" ({skipped_targets} skipped, already in targets file)" if skipped_targets else "")
        + f" -> {args.targets_out}"
        + (f" ; merged -> {args.merged_out}" if args.merged_out else "")
        + phase2_extra
    )
    p2_bar = _try_tqdm(len(indexed), p2_label, enabled=use_pbar) if indexed else None
    try:
        if not indexed:
            print("Phase 2: nothing to generate (all rows already had targets).", flush=True)
        elif args.phase2_message_batch:
            batch_fail_path = args.targets_out.with_name(args.targets_out.stem + ".batch_failures.jsonl")
            batch_fail_append = bool(
                args.phase2_resume and batch_fail_path.exists() and batch_fail_path.stat().st_size > 0
            )
            batch_fail_mode = "a" if batch_fail_append else "w"
            with open(args.targets_out, targets_mode, encoding="utf-8") as ftgt, open(
                fail_targets, "a", encoding="utf-8"
            ) as flog_t, open(batch_fail_path, batch_fail_mode, encoding="utf-8") as fbatch_fail, open(
                val_relaxed_path, val_relaxed_mode, encoding="utf-8"
            ) as fval_relaxed:
                batch_out = run_phase2_teacher_batches(
                    client,
                    indexed,
                    input_rows,
                    args.model,
                    chunk_size=max(1, args.phase2_batch_chunk_size),
                    poll_seconds=max(1, args.phase2_batch_poll_seconds),
                    teacher_retries=args.teacher_retries,
                    rescue_with_sync=args.phase2_batch_rescue,
                )
                done = 0
                for i, _row in sorted(indexed, key=lambda p: p[0]):
                    res = batch_out[i]
                    results_p2[i] = res
                    if res.ok and res.row:
                        with write_lock:
                            ftgt.write(json.dumps(res.row, ensure_ascii=False) + "\n")
                            ftgt.flush()
                            input_row = input_rows[res.index]
                            merged = dict(input_row)
                            merged["target"] = {"suggestions": res.row["suggestions"]}
                            record_row_into_stats(merged, stats)
                            if merged_fout:
                                merged_fout.write(json.dumps(merged, ensure_ascii=False) + "\n")
                                merged_fout.flush()
                            if not res.validated:
                                stats["targets_validation_relaxed"] += 1
                                if res.validation_error:
                                    stats["failure_buckets"][
                                        f"phase2_validation_relaxed:{failure_bucket(res.validation_error)}"
                                    ] += 1
                                sid_v = input_row.get("sample_id", res.index)
                                flog_t.write(
                                    f"{sid_v} phase2_teacher_batch_validation_relaxed: {res.validation_error}\n"
                                )
                                flog_t.flush()
                                fval_relaxed.write(
                                    json.dumps(
                                        {
                                            "sample_id": sid_v,
                                            "validation_error": res.validation_error,
                                            "raw_assistant_text": res.raw_assistant_text,
                                        },
                                        ensure_ascii=False,
                                    )
                                    + "\n"
                                )
                                fval_relaxed.flush()
                    else:
                        with write_lock:
                            sid = input_rows[res.index].get("sample_id", res.index)
                            flog_t.write(f"{sid} phase2_teacher_batch: {res.error}\n")
                            flog_t.flush()
                            fbatch_fail.write(
                                json.dumps(
                                    {
                                        "sample_id": sid,
                                        "error": res.error,
                                        "raw_assistant_text": res.raw_assistant_text,
                                    },
                                    ensure_ascii=False,
                                )
                                + "\n"
                            )
                            fbatch_fail.flush()
                            stats["failure_buckets"][f"phase2:{failure_bucket(res.error)}"] += 1
                    done += 1
                    if p2_bar:
                        p2_bar.update(1)
                    elif done % progress_log_interval == 0 or done == len(indexed):
                        print(f"  Phase 2 progress {done}/{len(indexed)}")
        else:
            with open(args.targets_out, targets_mode, encoding="utf-8") as ftgt, open(
                fail_targets, "a", encoding="utf-8"
            ) as flog_t, open(val_relaxed_path, val_relaxed_mode, encoding="utf-8") as fval_relaxed:
                with ThreadPoolExecutor(max_workers=max(1, args.workers)) as ex:
                    futs = {ex.submit(job_phase2, pair): pair for pair in indexed}
                    done = 0
                    for fut in as_completed(futs):
                        pair = futs[fut]
                        try:
                            res = fut.result()
                        except Exception as e:
                            res = GenResult(pair[0], False, None, str(e))
                        results_p2[res.index] = res
                        done += 1
                        if res.ok and res.row:
                            with write_lock:
                                ftgt.write(json.dumps(res.row, ensure_ascii=False) + "\n")
                                ftgt.flush()
                                input_row = input_rows[res.index]
                                merged = dict(input_row)
                                merged["target"] = {"suggestions": res.row["suggestions"]}
                                record_row_into_stats(merged, stats)
                                if merged_fout:
                                    merged_fout.write(json.dumps(merged, ensure_ascii=False) + "\n")
                                    merged_fout.flush()
                                if not res.validated:
                                    stats["targets_validation_relaxed"] += 1
                                    if res.validation_error:
                                        stats["failure_buckets"][
                                            f"phase2_validation_relaxed:{failure_bucket(res.validation_error)}"
                                        ] += 1
                                    sid_v = input_row.get("sample_id", res.index)
                                    flog_t.write(
                                        f"{sid_v} phase2_teacher_validation_relaxed: {res.validation_error}\n"
                                    )
                                    flog_t.flush()
                                    fval_relaxed.write(
                                        json.dumps(
                                            {
                                                "sample_id": sid_v,
                                                "validation_error": res.validation_error,
                                                "raw_assistant_text": res.raw_assistant_text,
                                            },
                                            ensure_ascii=False,
                                        )
                                        + "\n"
                                    )
                                    fval_relaxed.flush()
                        else:
                            with write_lock:
                                sid = input_rows[res.index].get("sample_id", res.index)
                                flog_t.write(f"{sid} phase2_teacher: {res.error}\n")
                                flog_t.flush()
                                stats["failure_buckets"][f"phase2:{failure_bucket(res.error)}"] += 1
                        if p2_bar:
                            p2_bar.update(1)
                        elif done % progress_log_interval == 0 or done == len(indexed):
                            print(f"  Phase 2 progress {done}/{len(indexed)}")
    finally:
        if p2_bar:
            p2_bar.close()
        if merged_fout:
            merged_fout.close()

    ok_p2 = sum(1 for r in results_p2 if r and r.ok)
    stats["teacher_pass_invoked"] = len(input_rows)
    stats["teacher_pass_fallback"] = len(input_rows) - ok_p2
    stats["targets_ok"] = ok_p2
    print(f"Phase 2 done. targets_ok={ok_p2}/{len(input_rows)} -> {args.targets_out}")
    summary_path = args.targets_out.with_name(args.targets_out.stem + ".summary.json")
    summary = build_run_summary(stats, len(plans), ok_p1, args)
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Quality summary -> {summary_path}")
    return 0 if ok_p1 == len(plans) and ok_p2 == len(input_rows) else 1


def main() -> int:
    argv = sys.argv[1:]
    if argv and argv[0] == "depolish-screen":
        return cmd_depolish_screen(argv[1:])
    return cmd_distill(argv)


__all__ = ["main", "cmd_distill", "cmd_depolish_screen"]
