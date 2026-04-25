"""Phase 2 teacher via Anthropic Message Batches (discounted) + prompt cache; optional sync rescue."""

from __future__ import annotations

import time
from typing import Any

from .generation import (
    GenResult,
    build_teacher_batch_message_params,
    phase2_teacher_dict_to_gen_result,
    refine_suggestions_with_teacher,
    teacher_response_text_to_gen_result,
)


def _assistant_text_from_message(message: Any) -> str:
    parts: list[str] = []
    for block in message.content or []:
        if getattr(block, "type", None) == "text":
            parts.append(block.text)
    return "".join(parts)


def _batch_item_error_message(result: Any) -> str:
    if result.type == "errored":
        err = getattr(result, "error", None)
        if err is not None:
            inner = getattr(err, "error", err)
            msg = getattr(inner, "message", None)
            if msg:
                return str(msg)
            return str(inner)
        return "batch_errored"
    if result.type == "canceled":
        return "batch_canceled"
    if result.type == "expired":
        return "batch_expired"
    return f"batch_non_success:{getattr(result, 'type', result)}"


def run_phase2_teacher_batches(
    client: Any,
    indexed: list[tuple[int, dict[str, Any]]],
    input_rows: list[dict[str, Any]],
    model: str,
    *,
    chunk_size: int,
    poll_seconds: float,
    teacher_retries: int,
    rescue_with_sync: bool = False,
) -> dict[int, GenResult]:
    """Run teacher for ``indexed`` (original_row_index, row) pairs using Message Batches.

    Each chunk is one batch job. Rows whose model output is not JSON / not three suggestions, or batch
    transport errors, are failures (``raw_assistant_text`` when the batch item succeeded). Parseable
    three-suggestion rows that fail ``validate_record`` are still returned as ``ok`` with
    ``validated=False`` (same ``sample_id`` + ``suggestions`` shape as strict passes). Set
    ``rescue_with_sync=True`` to retry hard failures with ``refine_suggestions_with_teacher``.
    """
    out: dict[int, GenResult] = {}
    if not indexed:
        return out

    n_chunks = (len(indexed) + chunk_size - 1) // chunk_size
    for c_i in range(n_chunks):
        chunk = indexed[c_i * chunk_size : (c_i + 1) * chunk_size]
        requests: list[dict[str, Any]] = []
        for i, row in chunk:
            requests.append(
                {
                    "custom_id": f"row{i}",
                    "params": build_teacher_batch_message_params(row, model),
                }
            )

        batch = client.messages.batches.create(requests=requests)
        bid = batch.id
        print(
            f"  Message Batch {bid}: {len(requests)} requests (chunk {c_i + 1}/{n_chunks}), waiting for completion…",
            flush=True,
        )

        while True:
            b = client.messages.batches.retrieve(message_batch_id=bid)
            if b.processing_status == "ended":
                break
            time.sleep(max(1.0, float(poll_seconds)))

        decoder = client.messages.batches.results(message_batch_id=bid)
        by_index: dict[int, GenResult] = {}
        try:
            for item in decoder:
                cid = item.custom_id
                if not cid.startswith("row"):
                    continue
                idx = int(cid[3:])
                br = item.result
                if br.type == "succeeded":
                    raw = _assistant_text_from_message(br.message)
                    row = input_rows[idx]
                    by_index[idx] = teacher_response_text_to_gen_result(idx, row, raw)
                else:
                    by_index[idx] = GenResult(idx, False, None, _batch_item_error_message(br), None)
        finally:
            close = getattr(decoder, "close", None)
            if callable(close):
                close()

        expected = {i for i, _ in chunk}
        for i in expected:
            if i not in by_index:
                by_index[i] = GenResult(i, False, None, "missing_batch_result_line", None)

        if rescue_with_sync:
            need_rescue = [i for i in expected if not by_index[i].ok]
            if need_rescue:
                print(f"  Batch chunk rescue (sync): {len(need_rescue)} rows…", flush=True)
            for i in need_rescue:
                row = input_rows[i]
                try:
                    refined = refine_suggestions_with_teacher(
                        client,
                        model,
                        dict(row),
                        None,
                        max_retries=teacher_retries,
                    )
                    by_index[i] = phase2_teacher_dict_to_gen_result(i, row, refined)
                except Exception as e:
                    by_index[i] = GenResult(i, False, None, f"{type(e).__name__}: {e}", None)

        out.update(by_index)

    return out
