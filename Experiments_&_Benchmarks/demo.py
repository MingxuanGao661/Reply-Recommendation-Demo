#!/usr/bin/env python3
"""Reply Assistant Demo — local model & cloud API dual-path testing CLI."""

import argparse
import json
import glob
import os
import sys
from datetime import datetime

from dotenv import load_dotenv
from schemas import ConversationInput, SuggestionOutput, EvalMetrics

#How you could run the inference locally:
#python demo.py local 
#python demo.py local --model gemma-4-E4B-it-Q4_K_M.gguf
#python demo.py benchmark --limit 0
#python demo.py cloud --provider anthropic


PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
# Load .env from this folder first so cloud keys work even if shell cwd is elsewhere.
load_dotenv(os.path.join(PROJECT_DIR, ".env"))
load_dotenv()
REPO_ROOT = os.path.dirname(PROJECT_DIR)
MODELS_DIR = os.path.join(PROJECT_DIR, "models")
REPO_MODELS_DIR = os.path.join(REPO_ROOT, "models")
REPLY_DIR = os.path.join(PROJECT_DIR, "results", "Reply")
EVAL_DIR = os.path.join(PROJECT_DIR, "results", "Eval")
DEFAULT_MODEL = "Llama-3.2-1B-Instruct-Q4_K_M.gguf"
DEFAULT_MODEL_PATH = os.path.join(
    REPO_ROOT,
    "Reply Recommendation Demo",
    "Reply Recommendation Demo",
    DEFAULT_MODEL,
)
DEFAULT_SAMPLES = os.path.join(REPO_ROOT, "social_reply_test_samples_26.json")


def _model_scan_dirs(extra_dirs: list[str] | None) -> list[str]:
    demo_bundle = os.path.join(REPO_ROOT, "Reply Recommendation Demo", "Reply Recommendation Demo")
    dirs = [
        MODELS_DIR,
        REPO_MODELS_DIR,
        PROJECT_DIR,
        demo_bundle,
    ]
    if extra_dirs:
        dirs.extend(extra_dirs)
    return dirs


def find_local_models(extra_dirs: list[str] | None = None) -> list[str]:
    """Collect *.gguf paths.

    Dedupes by basename first (same model in models/ and Xcode bundle → one run;
    prefers earlier dirs: old_python_files/models, repo models/, …).
    Also skips same realpath duplicates.
    """
    seen_base: set[str] = set()
    seen_real: set[str] = set()
    out: list[str] = []
    for d in _model_scan_dirs(extra_dirs):
        for p in sorted(glob.glob(os.path.join(d, "*.gguf"))):
            base = os.path.basename(p)
            r = os.path.realpath(p)
            if base in seen_base or r in seen_real:
                continue
            seen_base.add(base)
            seen_real.add(r)
            out.append(p)
    return sorted(out, key=os.path.basename)


def save_results(model_name: str, sample_results: list[dict], all_metrics: list[EvalMetrics]):
    """Save reply JSON to Reply/ and evaluation JSON to Eval/."""
    os.makedirs(REPLY_DIR, exist_ok=True)
    os.makedirs(EVAL_DIR, exist_ok=True)

    safe_name = model_name.replace("/", "_").replace(" ", "_")
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

    # --- Reply JSON: pure suggestions ---
    reply_file = os.path.join(REPLY_DIR, f"{safe_name}_reply_{timestamp}.json")
    reply_data = {
        "model_name": model_name,
        "timestamp": datetime.now().isoformat(),
        "samples": [
            {
                "sample_index": s["sample_index"],
                "draft": s["draft"],
                "suggestions": s.get("suggestions", []),
            }
            for s in sample_results
            if "suggestions" in s
        ],
    }
    with open(reply_file, "w", encoding="utf-8") as f:
        json.dump(reply_data, f, indent=2, ensure_ascii=False)

    # --- Eval JSON: full report (suggestions + metrics) ---
    eval_file = os.path.join(EVAL_DIR, f"{safe_name}_evaluation_{timestamp}.json")
    avg_latency = sum(m.latency_ms for m in all_metrics) / len(all_metrics) if all_metrics else 0
    avg_tps = sum(m.tokens_per_sec for m in all_metrics) / len(all_metrics) if all_metrics else 0

    eval_data = {
        "model_name": model_name,
        "timestamp": datetime.now().isoformat(),
        "num_samples": len(sample_results),
        "summary": {
            "avg_latency_ms": round(avg_latency, 1),
            "avg_tokens_per_sec": round(avg_tps, 1),
            "total_samples_run": len(all_metrics),
            "total_samples_failed": len(sample_results) - len(all_metrics),
        },
        "samples": sample_results,
        "per_sample_metrics": [m.to_dict() for m in all_metrics],
    }
    with open(eval_file, "w", encoding="utf-8") as f:
        json.dump(eval_data, f, indent=2, ensure_ascii=False)

    print(f"\nReply saved to:      {reply_file}")
    print(f"Evaluation saved to: {eval_file}")
    return reply_file, eval_file


def run_local(
    model_path: str,
    samples: list[dict],
    max_tokens: int,
    temperature: float,
    chat_format: str | None = None,
):
    from engine_local import LocalEngine

    model_name = os.path.basename(model_path).replace(".gguf", "")
    print(f"LOCAL MODE — {model_name}")
    if chat_format:
        print(f"  chat_format={chat_format!r} (CLI override)")

    engine = LocalEngine(model_path, chat_format=chat_format)

    all_metrics = []
    sample_results = []

    for i, sample in enumerate(samples):
        conv_input = ConversationInput.from_dict(sample)
        print(f"\n--- Sample {i+1}/{len(samples)} ---")
        print(f"Draft: \"{conv_input.draft}\"")

        try:
            output, metrics = engine.generate(conv_input, max_tokens=max_tokens, temperature=temperature)
        except Exception as e:
            print(f"\n  Error: {e}")
            sample_results.append({
                "sample_index": i,
                "draft": conv_input.draft,
                "error": str(e),
            })
            continue

        print("\nSuggestions:")
        for s in output.suggestions:
            print(f"  [{s.label}] {s.text}")

        print(f"\nMetrics:")
        print(f"  {metrics.summary()}")

        all_metrics.append(metrics)
        sample_results.append({
            "sample_index": i,
            "draft": conv_input.draft,
            "suggestions": output.to_dict()["suggestions"],
            "metrics": metrics.to_dict(),
        })

    engine.unload()

    if len(all_metrics) > 1:
        avg_latency = sum(m.latency_ms for m in all_metrics) / len(all_metrics)
        avg_tps = sum(m.tokens_per_sec for m in all_metrics) / len(all_metrics)
        print(f"\nAVERAGE — {len(all_metrics)} samples")
        print(f"  Avg latency:    {avg_latency:.0f} ms")
        print(f"  Avg tokens/sec: {avg_tps:.1f}")

    save_results(model_name, sample_results, all_metrics)
    return all_metrics


def run_cloud(provider: str, samples: list[dict], max_tokens: int, temperature: float, model: str | None = None):
    from engine_cloud import CloudEngine, ENV_KEY_MAP

    env_var = ENV_KEY_MAP.get(provider, f"{provider.upper()}_API_KEY")
    api_key = os.getenv(env_var)
    if not api_key:
        print(f"Error: {env_var} not set. Add it to .env or export it:")
        print(f"  export {env_var}=your_key_here")
        sys.exit(1)

    try:
        engine = CloudEngine(api_key=api_key, provider=provider, model=model)
    except (ValueError, ImportError) as e:
        print(f"Error initializing engine: {e}")
        sys.exit(1)

    print(f"CLOUD MODE — {engine.model_name}")

    all_metrics = []
    sample_results = []

    for i, sample in enumerate(samples):
        conv_input = ConversationInput.from_dict(sample)
        print(f"\n--- Sample {i+1}/{len(samples)} ---")
        print(f"Draft: \"{conv_input.draft}\"")

        try:
            output, metrics = engine.generate(conv_input, max_tokens=max_tokens, temperature=temperature)
        except (RuntimeError, Exception) as e:
            print(f"\n  Error: {e}")
            sample_results.append({
                "sample_index": i,
                "draft": conv_input.draft,
                "error": str(e),
            })
            continue

        print("\nSuggestions:")
        for s in output.suggestions:
            print(f"  [{s.label}] {s.text}")

        print(f"\nMetrics:")
        print(f"  {metrics.summary()}")

        all_metrics.append(metrics)
        sample_results.append({
            "sample_index": i,
            "draft": conv_input.draft,
            "suggestions": output.to_dict()["suggestions"],
            "metrics": metrics.to_dict(),
        })

    if len(all_metrics) > 1:
        avg_latency = sum(m.latency_ms for m in all_metrics) / len(all_metrics)
        print(f"\nAVERAGE — {len(all_metrics)} samples")
        print(f"  Avg latency: {avg_latency:.0f} ms")

    save_results(engine.model_name, sample_results, all_metrics)
    return all_metrics


def run_benchmark(
    samples: list[dict],
    max_tokens: int,
    temperature: float,
    models_dirs: list[str] | None = None,
):
    """Run all local models and compare results."""
    models = find_local_models(extra_dirs=models_dirs)
    if not models:
        print("No .gguf models found. Scanned these directories:")
        for d in _model_scan_dirs(models_dirs):
            print(f"  - {d}")
        return

    print(f"\nFound {len(models)} local models:")
    for m in models:
        print(f"  - {os.path.basename(m)}")

    results = {}
    for model_path in models:
        metrics = run_local(model_path, samples, max_tokens, temperature)
        name = os.path.basename(model_path)
        if metrics:
            avg_latency = sum(m.latency_ms for m in metrics) / len(metrics)
            avg_tps = sum(m.tokens_per_sec for m in metrics) / len(metrics)
            results[name] = {"avg_latency_ms": avg_latency, "avg_tokens_per_sec": avg_tps}

    print(f"\n{'='*65}")
    print("BENCHMARK SUMMARY")
    print(f"{'='*65}")
    print(f"{'Model':<45} {'Latency':>10} {'Tok/s':>8}")
    print(f"{'-'*45} {'-'*10} {'-'*8}")
    for name, r in sorted(results.items(), key=lambda x: x[1]["avg_latency_ms"]):
        print(f"{name:<45} {r['avg_latency_ms']:>8.0f}ms {r['avg_tokens_per_sec']:>7.1f}")


def load_samples(path: str | None, limit: int) -> list[dict]:
    if not path or not os.path.exists(path):
        print(f"Error: Samples file not found: {path}")
        print("Provide a JSON file with test conversations, e.g.:")
        print("  python demo.py local --samples ../social_reply_test_samples_26.json")
        sys.exit(1)

    try:
        with open(path) as f:
            samples = json.load(f)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON in {path}: {e}")
        sys.exit(1)

    if not isinstance(samples, list) or not samples:
        print("Error: Samples file must be a non-empty JSON array.")
        sys.exit(1)

    if limit <= 0:
        return samples
    return samples[:limit]


def main():
    parser = argparse.ArgumentParser(description="Reply Assistant Demo")
    sub = parser.add_subparsers(dest="mode", help="Execution mode")

    # --- local mode ---
    p_local = sub.add_parser("local", help="Run with local GGUF model")
    p_local.add_argument("--model", type=str, help="Path to .gguf model (default: auto-detect)")
    p_local.add_argument("--samples", type=str, default=DEFAULT_SAMPLES, help="Path to test samples JSON")
    p_local.add_argument("--limit", type=int, default=3, help="Max samples (0 = entire JSON file)")
    p_local.add_argument("--max-tokens", type=int, default=512)
    p_local.add_argument("--temperature", type=float, default=0.7)
    p_local.add_argument(
        "--chat-format",
        type=str,
        default=None,
        metavar="NAME",
        help="llama-cpp-python chat_format (e.g. gemma). Default: auto — gemma* GGUF uses gemma",
    )

    # --- cloud mode ---
    p_cloud = sub.add_parser("cloud", help="Run with cloud API")
    p_cloud.add_argument("--provider", type=str, default="openai",
                         choices=["openai", "anthropic", "gemini", "groq", "together", "openrouter"])
    p_cloud.add_argument("--list-models", action="store_true", help="Show available models per provider")
    p_cloud.add_argument("--model", type=str, default=None, help="Model name (default: provider's default)")
    p_cloud.add_argument("--samples", type=str, default=DEFAULT_SAMPLES, help="Path to test samples JSON")
    p_cloud.add_argument("--limit", type=int, default=3, help="Max samples (0 = entire JSON file)")
    p_cloud.add_argument("--max-tokens", type=int, default=512)
    p_cloud.add_argument("--temperature", type=float, default=0.7)

    # --- benchmark mode ---
    p_bench = sub.add_parser("benchmark", help="Run all local models and compare")
    p_bench.add_argument("--samples", type=str, default=DEFAULT_SAMPLES, help="Path to test samples JSON")
    p_bench.add_argument("--limit", type=int, default=3, help="Max samples (0 = entire JSON file)")
    p_bench.add_argument(
        "--models-dir",
        action="append",
        default=None,
        dest="models_dirs",
        metavar="DIR",
        help="Extra folder to scan for *.gguf (repeatable). Default: old_python_files/models, repo-root models/, project dir, Reply Demo bundle",
    )
    p_bench.add_argument("--max-tokens", type=int, default=512)
    p_bench.add_argument("--temperature", type=float, default=0.7)

    args = parser.parse_args()

    if not args.mode:
        parser.print_help()
        sys.exit(0)

    if args.mode == "cloud" and getattr(args, "list_models", False):
        from engine_cloud import list_providers
        print("Available cloud models:")
        list_providers()
        sys.exit(0)

    samples = load_samples(getattr(args, "samples", None), args.limit)
    print(f"Loaded {len(samples)} test sample(s).")

    if args.mode == "local":
        model_path = args.model
        if not model_path:
            if os.path.exists(DEFAULT_MODEL_PATH):
                model_path = DEFAULT_MODEL_PATH
                print(f"Using default model: {DEFAULT_MODEL_PATH}")
            else:
                default_path = os.path.join(MODELS_DIR, DEFAULT_MODEL)
                if os.path.exists(default_path):
                    model_path = default_path
                    print(f"Using default model: {DEFAULT_MODEL}")
        if not model_path:
            models = find_local_models()
            if not models:
                print("No .gguf models found. Put .gguf files in old_python_files/models/ or LA-Hacks/models/.")
                sys.exit(1)
            print("Available models:")
            for i, m in enumerate(models):
                print(f"  [{i}] {os.path.basename(m)}")
            choice = input(f"Select model [0-{len(models)-1}]: ").strip()
            model_path = models[int(choice)]
        elif not os.path.exists(model_path):
            full_path = os.path.join(MODELS_DIR, model_path)
            if os.path.exists(full_path):
                model_path = full_path
            elif os.path.basename(model_path) == DEFAULT_MODEL and os.path.exists(DEFAULT_MODEL_PATH):
                model_path = DEFAULT_MODEL_PATH
            else:
                print(f"Error: Model file not found: {model_path}")
                sys.exit(1)
        run_local(
            model_path,
            samples,
            args.max_tokens,
            args.temperature,
            chat_format=args.chat_format,
        )

    elif args.mode == "cloud":
        run_cloud(args.provider, samples, args.max_tokens, args.temperature, model=args.model)

    elif args.mode == "benchmark":
        run_benchmark(samples, args.max_tokens, args.temperature, models_dirs=args.models_dirs)


if __name__ == "__main__":
    main()
