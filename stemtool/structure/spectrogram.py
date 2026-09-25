"""The model's input: a log-frequency spectrogram per instrument.

Reimplements the madmom chain All-In-One was trained with (FramedSignal at 100 fps
with 2048-sample frames, a Hann-windowed STFT, a logarithmic filterbank with 12
bands per octave from 30 Hz to 17 kHz with normalized filters, log10(1 + x)),
in plain NumPy, so madmom (whose package also contains non-commercial model files)
is not needed. tests/test_structure.py checks the result against madmom when it
is installed.
"""

from __future__ import annotations

from functools import lru_cache

import numpy as np

SAMPLE_RATE = 44100
FRAME_SIZE = 2048
HOP = 441  # 100 frames per second
FMIN, FMAX, FREF, BANDS_PER_OCTAVE = 30.0, 17000.0, 440.0, 12


def _log_frequencies() -> np.ndarray:
    left = np.floor(np.log2(FMIN / FREF) * BANDS_PER_OCTAVE)
    right = np.ceil(np.log2(FMAX / FREF) * BANDS_PER_OCTAVE)
    freqs = FREF * 2.0 ** (np.arange(left, right) / BANDS_PER_OCTAVE)
    return freqs[(freqs >= FMIN) & (freqs <= FMAX)]


@lru_cache(maxsize=1)
def filterbank() -> np.ndarray:
    """[bins, bands] triangular filters on the FFT bins, each summing to 1."""
    bin_freqs = np.fft.fftfreq(FRAME_SIZE, 1.0 / SAMPLE_RATE)[: FRAME_SIZE // 2]
    # nearest bin, the way madmom rounds (searchsorted, then pick the closer neighbour)
    freqs = _log_frequencies()
    idx = np.searchsorted(bin_freqs, freqs)
    idx = np.clip(idx, 1, len(bin_freqs) - 1)
    left, right = bin_freqs[idx - 1], bin_freqs[idx]
    idx -= freqs - left < right - freqs
    bins = np.unique(idx)

    filters = []
    for start, center, stop in zip(bins[:-2], bins[1:-1], bins[2:]):
        if stop - start < 2:  # too narrow: a single-bin filter
            center, stop = start, start + 1
        f = np.zeros(len(bin_freqs))
        rise = np.linspace(0, 1, center - start, endpoint=False)
        fall = np.linspace(1, 0, stop - center, endpoint=False)
        f[start:center] = rise
        f[center:stop] = fall
        if f.sum() > 0:
            f /= f.sum()
        filters.append(f)
    return np.stack(filters, axis=1).astype(np.float32)


def spectrogram(mono: np.ndarray) -> np.ndarray:
    """mono: float samples at 44.1 kHz in [-1, 1]. Returns [frames, bands] float32."""
    n_frames = int(np.ceil(len(mono) / HOP))
    padded = np.concatenate([np.zeros(FRAME_SIZE // 2, np.float32), mono.astype(np.float32),
                             np.zeros(FRAME_SIZE, np.float32)])
    window = np.hanning(FRAME_SIZE).astype(np.float32)
    fb = filterbank()
    out = np.empty((n_frames, fb.shape[1]), np.float32)
    chunk = 2048  # frames per batch, to keep memory small
    for s in range(0, n_frames, chunk):
        idx = np.arange(s, min(n_frames, s + chunk))[:, None] * HOP + np.arange(FRAME_SIZE)
        frames = padded[idx] * window
        mag = np.abs(np.fft.rfft(frames, axis=1))[:, : FRAME_SIZE // 2]
        out[s:s + len(idx)] = np.log10(1 + mag @ fb)
    return out
