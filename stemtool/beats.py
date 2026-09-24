"""Beat and downbeat tracking with beat_this (CPJKU)."""

from __future__ import annotations

import threading

import numpy as np

_lock = threading.Lock()
_tracker = None
_tracker_key: tuple[str, str] | None = None


def _get_tracker(checkpoint: str, device: str):
    global _tracker, _tracker_key
    with _lock:
        if _tracker is None or _tracker_key != (checkpoint, device):
            from beat_this.inference import Audio2Beats

            _tracker = Audio2Beats(checkpoint_path=checkpoint, device=device, dbn=False)
            _tracker_key = (checkpoint, device)
        return _tracker


def track(mono: np.ndarray, sample_rate: int, checkpoint: str, device: str) -> tuple[list[float], list[float]]:
    """mono: 1-D float array. Returns (beats, downbeats) in seconds."""
    tracker = _get_tracker(checkpoint, device)
    beats, downbeats = tracker(mono, sample_rate)
    return [round(float(b), 4) for b in beats], [round(float(d), 4) for d in downbeats]


def estimate_bpm(beats: list[float]) -> float | None:
    if len(beats) < 4:
        return None
    return round(60.0 / float(np.median(np.diff(beats))), 1)


def beats_per_bar(beats: list[float], downbeats: list[float]) -> int:
    """Most common number of beats between consecutive downbeats (4 if unclear)."""
    if len(downbeats) < 3 or len(beats) < 4:
        return 4
    b = np.asarray(beats)
    counts = [int(np.sum((b >= d0 - 0.03) & (b < d1 - 0.03))) for d0, d1 in zip(downbeats, downbeats[1:])]
    counts = [c for c in counts if 2 <= c <= 12]
    if not counts:
        return 4
    values, freq = np.unique(counts, return_counts=True)
    return int(values[np.argmax(freq)])
