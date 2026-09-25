"""Section boundaries from the model's boundary probability, following All-In-One's
postprocess_functional_structure (local maxima over about one beat, then peak
picking against the mean of the surrounding 12 seconds)."""

from __future__ import annotations

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

FPS = 100
LOCAL_MAX_FRAMES = 4 * 24 + 1  # 4 * min_hops_per_beat + 1, as in All-In-One
PEAK_WINDOW = 12 * FPS
MIN_GAP = 2 * FPS


def _local_maxima(x: np.ndarray, size: int) -> np.ndarray:
    pad = size // 2
    padded = np.pad(x, pad, constant_values=-np.inf)
    window_max = sliding_window_view(padded, size).max(axis=-1)
    return np.where(x == window_max, x, 0.0)


def _peak_picking(activation: np.ndarray, past: int, future: int) -> np.ndarray:
    size = past + future + 1
    padded = np.pad(activation, (past, future))
    is_max = (activation == sliding_window_view(padded, size).max(axis=-1)) & (activation > 0)
    past_mean = sliding_window_view(padded[:-(future + 1)], past).mean(axis=-1)
    future_mean = sliding_window_view(padded[past + 1:], future).mean(axis=-1)
    strength = activation - (past_mean + future_mean) / 2
    out = np.zeros_like(activation)
    idx = np.flatnonzero(is_max)
    out[idx] = strength[idx]
    return out


def boundaries(prob_section: np.ndarray) -> list[int]:
    """Frame indices where a new section starts."""
    peaks = _local_maxima(prob_section, LOCAL_MAX_FRAMES)
    strength = _peak_picking(peaks, PEAK_WINDOW, PEAK_WINDOW)
    # Ties (two equal frames at the top of a peak) would give two boundaries a frame
    # apart: keep the strongest candidate within MIN_GAP frames.
    chosen: list[int] = []
    for i in sorted(np.flatnonzero(strength > 0), key=lambda i: -strength[i]):
        if all(abs(i - c) >= MIN_GAP for c in chosen):
            chosen.append(int(i))
    return sorted(chosen)
