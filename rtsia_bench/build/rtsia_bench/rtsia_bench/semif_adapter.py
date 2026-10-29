"""Adapter around SemIf (https://github.com/TheoLeeCJ/SemIf-OpenJev).

Uses the SemIf PyTorch backend (package `semif_phase1`), the same code path as
`semif-score --backend torch`. The SemIf llama.cpp backend is NOT used: it
hard-codes `n_gpu_layers = 0`, so it would run on the Orin CPU only.

Modes:
  - "direct": one full forward pass per decision (default, recommended for a
    sensor stream, where the state changes at every sample).
  - "serial": SemIf's state-prefix cache. It only pays off when consecutive
    decisions share the exact same state (e.g. several questions per sample);
    with a changing state every call is a cache miss plus a cache copy.

Timing: SemIf synchronizes the CUDA device around the forward pass and reads
the option logits back to the CPU, so the returned times are real execution
times, not kernel launch times.
"""
from __future__ import annotations

from .common import QUESTION, OPTIONS

MODEL = "Qwen/Qwen3.5-4B"
REVISION = "851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a"

# Dummy decision used only to warm up CUDA kernels and allocator before measuring.
WARMUP_ROW = {
    "id": "warmup",
    "state": {"obstacle_distance_m": 2.0, "motor_temperature_c": 60.0, "speed_m_s": 1.0},
    "question": QUESTION,
    "options": OPTIONS,
}


class SemifScorer:
    def __init__(self, model: str = MODEL, revision: str = REVISION, mode: str = "direct",
                 device: str = "cuda", dtype: str = "bfloat16", max_tokens: int = 4096,
                 warmup: int = 3):
        try:
            from semif_phase1.core import load_causal_model
            from semif_phase1.direct import score as direct_score
            from semif_phase1.serial import SerialPrefixScorer
        except ImportError as error:
            raise RuntimeError(
                "Cannot import SemIf. Activate the SemIf virtualenv and run "
                "`pip install -e . --no-deps` inside the SemIf-OpenJev repository."
            ) from error
        if mode not in ("direct", "serial"):
            raise ValueError("mode must be 'direct' or 'serial'")

        self.mode = mode
        self.max_tokens = max_tokens
        self._direct_score = direct_score
        self._serial_cls = SerialPrefixScorer
        # Pinned revision, BF16, exactly one visible CUDA device (the Orin iGPU).
        self.model, self.tokenizer, self.metadata = load_causal_model(model, revision, device, dtype)

        self._serial = self._new_serial() if mode == "serial" else None
        for _ in range(warmup):
            self.score_detailed(WARMUP_ROW)
        if mode == "serial":
            self._serial = self._new_serial()  # do not carry the warm-up state into the run

    def _new_serial(self):
        return self._serial_cls(self.model, self.tokenizer, self.metadata, self.max_tokens)

    def score_detailed(self, row: dict):
        """Score one row. Returns ({option_id: probability}, info)."""
        if self.mode == "serial":
            result = self._serial.score(row)
        else:
            result = self._direct_score(self.model, self.tokenizer, row, self.metadata, self.max_tokens)
        probs = dict(zip(result["option_ids"], result["probabilities"]))
        info = {
            "n_prompt_tokens": result["input_tokens"],
            # A single forward pass over the whole prompt: the analogue of LLM prefill.
            "forward_ms": result["forward_seconds"] * 1e3,
            # Includes chat templating and tokenization.
            "semif_total_ms": result["total_seconds"] * 1e3,
            "cache_hit": result.get("cache_hit"),
            "prompt_sha256": result["prompt_sha256"],
        }
        return probs, info

    def score(self, row: dict) -> dict:
        """Score one row. Returns {option_id: probability}."""
        return self.score_detailed(row)[0]
