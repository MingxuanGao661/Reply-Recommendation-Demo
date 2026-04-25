"""
Generate comparison charts from evaluation JSON files in results/Eval/.
Usage:
    python visualize.py                  # read all Eval JSONs
    python visualize.py --dir results/Eval  # specify directory
"""

import argparse
import json
import os
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

EVAL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", "Eval")
OUTPUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", "charts")


def load_eval_files(eval_dir: str) -> list[dict]:
    evals = []
    for f in sorted(Path(eval_dir).glob("*_evaluation_*.json")):
        with open(f, encoding="utf-8") as fh:
            data = json.load(fh)
            data["_file"] = f.name
            evals.append(data)
    return evals


def shorten_name(name: str) -> str:
    return (
        name.replace("-Instruct", "")
            .replace("-Q4_K_M", "\nQ4_K_M")
            .replace("-it", "")
    )


def extract_summary(evals: list[dict]) -> dict:
    models, latency, tps, mem_peak, cpu, model_size_mb = [], [], [], [], [], []

    for ev in evals:
        name = ev["model_name"]
        models.append(shorten_name(name))
        latency.append(ev["summary"]["avg_latency_ms"])
        tps.append(ev["summary"]["avg_tokens_per_sec"])

        peaks = [s["metrics"]["memory_after_mb"] for s in ev["samples"]]
        cpu_vals = [s["metrics"]["cpu_percent"] for s in ev["samples"]]
        mem_peak.append(max(peaks))
        cpu.append(np.mean(cpu_vals))

        gguf_path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "models", name + ".gguf"
        )
        if os.path.exists(gguf_path):
            model_size_mb.append(os.path.getsize(gguf_path) / (1024 * 1024))
        else:
            model_size_mb.append(0)

    return dict(
        models=models,
        latency=latency,
        tps=tps,
        mem_peak=mem_peak,
        cpu=cpu,
        model_size_mb=model_size_mb,
    )


def make_charts(data: dict, output_dir: str, evals: list[dict] = None):
    os.makedirs(output_dir, exist_ok=True)
    n = len(data["models"])
    x = np.arange(n)
    bar_w = 0.55
    _palette = [
        "#4C78A8", "#F58518", "#E45756", "#72B7B2", "#54A24B",
        "#B279A2", "#FF9DA6", "#9D755D", "#DDA0A0", "#AB6B51",
    ]
    colors = [_palette[i % len(_palette)] for i in range(n)]

    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    fig.suptitle("Model Evaluation Comparison", fontsize=16, fontweight="bold", y=0.98)

    # --- 1. Average Latency ---
    ax = axes[0, 0]
    bars = ax.bar(x, data["latency"], bar_w, color=colors, edgecolor="white", linewidth=0.8)
    ax.set_title("Average Latency (ms)  ↓ lower is better", fontsize=11)
    ax.set_ylabel("ms")
    ax.set_xticks(x)
    ax.set_xticklabels(data["models"], fontsize=8)
    for bar, val in zip(bars, data["latency"]):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 80,
                f"{val:.0f}", ha="center", va="bottom", fontsize=9, fontweight="bold")
    ax.set_ylim(0, max(data["latency"]) * 1.2)

    # --- 2. Tokens per Second ---
    ax = axes[0, 1]
    bars = ax.bar(x, data["tps"], bar_w, color=colors, edgecolor="white", linewidth=0.8)
    ax.set_title("Tokens per Second  ↑ higher is better", fontsize=11)
    ax.set_ylabel("tok/s")
    ax.set_xticks(x)
    ax.set_xticklabels(data["models"], fontsize=8)
    for bar, val in zip(bars, data["tps"]):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.3,
                f"{val:.1f}", ha="center", va="bottom", fontsize=9, fontweight="bold")
    ax.set_ylim(0, max(data["tps"]) * 1.25)

    # --- 3. Peak Memory ---
    ax = axes[1, 0]
    bars = ax.bar(x, data["mem_peak"], bar_w, color=colors, edgecolor="white", linewidth=0.8)
    ax.set_title("Peak Memory Usage (MB)  ↓ lower is better", fontsize=11)
    ax.set_ylabel("MB")
    ax.set_xticks(x)
    ax.set_xticklabels(data["models"], fontsize=8)
    for bar, val in zip(bars, data["mem_peak"]):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 15,
                f"{val:.0f}", ha="center", va="bottom", fontsize=9, fontweight="bold")
    ax.set_ylim(0, max(data["mem_peak"]) * 1.15)

    # --- 4. CPU Usage ---
    ax = axes[1, 1]
    bars = ax.bar(x, data["cpu"], bar_w, color=colors, edgecolor="white", linewidth=0.8)
    ax.set_title("Average CPU Usage (%)  ↓ lower is better", fontsize=11)
    ax.set_ylabel("%")
    ax.set_xticks(x)
    ax.set_xticklabels(data["models"], fontsize=8)
    for bar, val in zip(bars, data["cpu"]):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.5,
                f"{val:.1f}%", ha="center", va="bottom", fontsize=9, fontweight="bold")
    ax.set_ylim(0, max(data["cpu"]) * 1.2)

    plt.tight_layout(rect=[0, 0, 1, 0.95])
    path_4panel = os.path.join(output_dir, "model_comparison.png")
    fig.savefig(path_4panel, dpi=180, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved: {path_4panel}")

    # --- 5. Radar / summary table ---
    if any(s > 0 for s in data["model_size_mb"]):
        fig2, ax2 = plt.subplots(figsize=(10, 4))
        ax2.axis("off")
        headers = ["Model", "Size (MB)", "Latency (ms)", "Tok/s", "Peak Mem (MB)", "CPU (%)"]
        rows = []
        for i in range(n):
            rows.append([
                data["models"][i].replace("\n", " "),
                f"{data['model_size_mb'][i]:.0f}" if data["model_size_mb"][i] > 0 else "N/A",
                f"{data['latency'][i]:.0f}",
                f"{data['tps'][i]:.1f}",
                f"{data['mem_peak'][i]:.0f}",
                f"{data['cpu'][i]:.1f}%",
            ])

        table = ax2.table(
            cellText=rows, colLabels=headers, loc="center",
            cellLoc="center", colColours=["#E8EEF4"] * len(headers),
        )
        table.auto_set_font_size(False)
        table.set_fontsize(10)
        table.scale(1.0, 1.6)

        for (row, col), cell in table.get_celld().items():
            if row == 0:
                cell.set_text_props(fontweight="bold")
                cell.set_facecolor("#4C78A8")
                cell.set_text_props(color="white", fontweight="bold")
            elif row % 2 == 0:
                cell.set_facecolor("#F5F7FA")

        fig2.suptitle("Model Evaluation Summary", fontsize=14, fontweight="bold")
        path_table = os.path.join(output_dir, "model_summary_table.png")
        fig2.savefig(path_table, dpi=180, bbox_inches="tight")
        plt.close(fig2)
        print(f"Saved: {path_table}")

    # --- 6. Per-sample latency breakdown ---
    fig3, ax3 = plt.subplots(figsize=(12, 5))
    sample_indices = sorted({s["sample_index"] for ev in evals for s in ev["samples"]})
    bar_w2 = 0.8 / n
    for i, ev in enumerate(evals):
        name = shorten_name(ev["model_name"]).replace("\n", " ")
        sample_latencies = [s["metrics"]["latency_ms"] for s in ev["samples"]]
        positions = np.arange(len(sample_latencies)) + i * bar_w2
        ax3.bar(positions, sample_latencies, bar_w2, label=name, color=colors[i],
                edgecolor="white", linewidth=0.5)

    ax3.set_title("Per-Sample Latency Breakdown (ms)", fontsize=12, fontweight="bold")
    ax3.set_ylabel("ms")
    ax3.set_xlabel("Sample Index")
    ax3.set_xticks(np.arange(len(sample_indices)) + bar_w2 * (n - 1) / 2)
    ax3.set_xticklabels([f"Sample {si}" for si in sample_indices])
    ax3.legend(fontsize=8, loc="upper right")
    plt.tight_layout()
    path_breakdown = os.path.join(output_dir, "per_sample_latency.png")
    fig3.savefig(path_breakdown, dpi=180, bbox_inches="tight")
    plt.close(fig3)
    print(f"Saved: {path_breakdown}")


def main():
    parser = argparse.ArgumentParser(description="Visualize model evaluation results")
    parser.add_argument("--dir", default=EVAL_DIR, help="Eval JSON directory")
    parser.add_argument("--out", default=OUTPUT_DIR, help="Output chart directory")
    args = parser.parse_args()

    evals = load_eval_files(args.dir)
    if not evals:
        print(f"No evaluation files found in {args.dir}")
        return

    print(f"Found {len(evals)} evaluation(s):")
    for ev in evals:
        print(f"  - {ev['model_name']}")

    data = extract_summary(evals)
    make_charts(data, args.out, evals)
    print(f"\nAll charts saved to: {args.out}")


if __name__ == "__main__":
    main()
