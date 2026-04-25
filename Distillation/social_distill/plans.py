"""Diversity allocation for scene plans (docs §6)."""

from __future__ import annotations

import random
from typing import Any

from .constants import SCENE_TAGS


def build_scene_plans(n: int, seed: int = 42) -> list[dict[str, Any]]:
    """
    §6 proportions (any n >= 1), same mix as the original 400-row design:
      task: 50% from_scratch replyStyles, 30% rewrite replyStyles, 20% decision decisionReply,
            plus 5% of n from_scratch + decisionReply so theme stays ~75/25 vs task 50/30/20.
    Integer split: 20% decision+decisionReply, 5% scratch+decisionReply, 45% scratch+replyStyles,
    remainder rewrite+replyStyles.
    """
    if n < 1:
        raise ValueError("build_scene_plans: n must be >= 1")
    rng = random.Random(seed)
    n_dec = n * 20 // 100
    n_sdec = n * 5 // 100
    n_srs = n * 45 // 100
    n_rw = n - n_dec - n_sdec - n_srs
    if n_rw < 0:
        raise ValueError("internal: negative rewrite slot count")
    slots: list[tuple[str, str]] = (
        [("decision", "decisionReply")] * n_dec
        + [("from_scratch", "decisionReply")] * n_sdec
        + [("from_scratch", "replyStyles")] * n_srs
        + [("rewrite", "replyStyles")] * n_rw
    )
    assert len(slots) == n
    rng.shuffle(slots)

    rel = (
        ["friend"] * int(round(n * 0.30))
        + ["classmate"] * int(round(n * 0.20))
        + ["manager"] * int(round(n * 0.10))
        + ["colleague"] * int(round(n * 0.10))
        + ["romantic_interest"] * int(round(n * 0.15))
        + ["acquaintance"] * int(round(n * 0.15))
    )
    while len(rel) < n:
        rel.append("friend")
    rel = rel[:n]
    rng.shuffle(rel)

    group_flags = [False] * int(round(n * 0.80)) + [True] * int(round(n * 0.20))
    while len(group_flags) < n:
        group_flags.append(False)
    group_flags = group_flags[:n]
    rng.shuffle(group_flags)

    tones = (["casual"] * (n // 4) + ["warm"] * (n // 4) + ["professional"] * (n // 4) + ["direct"] * (n // 4))[:n]
    while len(tones) < n:
        tones.append(rng.choice(["casual", "warm", "professional", "direct"]))
    rng.shuffle(tones)

    lengths = (
        ["short"] * int(round(n * 0.50))
        + ["medium"] * int(round(n * 0.35))
        + ["long"] * int(round(n * 0.15))
    )
    lengths = lengths[:n]
    while len(lengths) < n:
        lengths.append("short")
    rng.shuffle(lengths)

    scene_cycle = list(SCENE_TAGS) * (n // len(SCENE_TAGS))
    while len(scene_cycle) < n:
        scene_cycle.append(rng.choice(SCENE_TAGS))
    scene_cycle = scene_cycle[:n]
    rng.shuffle(scene_cycle)

    risks = (
        ["low"] * int(round(n * 0.35))
        + ["medium"] * int(round(n * 0.45))
        + ["high"] * int(round(n * 0.20))
    )
    risks = risks[:n]
    while len(risks) < n:
        risks.append("medium")
    rng.shuffle(risks)

    dists = (
        ["close"] * int(round(n * 0.40))
        + ["medium"] * int(round(n * 0.40))
        + ["distant"] * int(round(n * 0.20))
    )
    dists = dists[:n]
    while len(dists) < n:
        dists.append("close")
    rng.shuffle(dists)

    turn_counts = [rng.randint(3, 6) for _ in range(n)]

    plans: list[dict[str, Any]] = []
    for i in range(n):
        tt, st = slots[i]
        plans.append(
            {
                "index": i,
                "task_type": tt,
                "suggestion_theme": st,
                "relationship": rel[i],
                "is_group": group_flags[i],
                "conversation_profile": {"tone": tones[i], "length": lengths[i]},
                "distillation_controls": {
                    "scene_tag": scene_cycle[i],
                    "social_risk": risks[i],
                    "relationship_distance": dists[i],
                },
                "approx_turns": turn_counts[i],
            }
        )
    return plans
