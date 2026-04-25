import time
import psutil
import os
from contextlib import contextmanager
from schemas import EvalMetrics


def _get_memory_mb() -> float:
    process = psutil.Process(os.getpid())
    return process.memory_info().rss / (1024 * 1024)


@contextmanager
def measure(model_name: str = ""):
    """Context manager that captures performance metrics around a block.

    Usage:
        with measure("llama-3.2-1b") as metrics:
            result = engine.generate(...)
        metrics.tokens_generated = ...
        print(metrics.summary())
    """
    metrics = EvalMetrics(model_name=model_name)
    metrics.memory_before_mb = _get_memory_mb()

    cpu_times_before = psutil.Process(os.getpid()).cpu_times()
    wall_start = time.perf_counter()

    yield metrics

    wall_end = time.perf_counter()
    cpu_times_after = psutil.Process(os.getpid()).cpu_times()

    elapsed_sec = wall_end - wall_start
    metrics.latency_ms = elapsed_sec * 1000

    metrics.memory_after_mb = _get_memory_mb()
    metrics.memory_delta_mb = metrics.memory_after_mb - metrics.memory_before_mb

    cpu_used = (
        (cpu_times_after.user - cpu_times_before.user)
        + (cpu_times_after.system - cpu_times_before.system)
    )
    metrics.cpu_percent = (cpu_used / elapsed_sec * 100) if elapsed_sec > 0 else 0.0

    if metrics.tokens_generated > 0 and elapsed_sec > 0:
        metrics.tokens_per_sec = metrics.tokens_generated / elapsed_sec
