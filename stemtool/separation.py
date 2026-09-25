"""Drums / no-drums separation with Demucs.

Uses Demucs' Python API directly instead of the `demucs` CLI. That avoids the CLI's
torchaudio-based file saving (which breaks with recent torchaudio) and keeps the model
loaded between songs.
"""

from __future__ import annotations

import threading

import numpy as np

_lock = threading.Lock()
_model = None
_model_name: str | None = None


def _get_model(name: str):
    global _model, _model_name
    with _lock:
        if _model is None or _model_name != name:
            from demucs.pretrained import get_model

            model = get_model(name)  # downloads weights on first use (~/.cache/torch)
            model.eval()
            _model, _model_name = model, name
        return _model


STEMS = ("drums", "bass", "vocals", "other")


def separate(mix: np.ndarray, sample_rate: int, model_name: str, device: str, shifts: int = 1) -> dict[str, np.ndarray]:
    """mix: samples x 2 float32. Returns {"drums", "bass", "vocals", "other"}, each
    shaped like mix; together they add up to Demucs' reconstruction of the mix."""
    import torch
    from demucs.apply import apply_model

    model = _get_model(model_name)
    if sample_rate != model.samplerate:
        raise ValueError(f"Expected {model.samplerate} Hz audio, got {sample_rate} Hz")

    wav = torch.from_numpy(np.ascontiguousarray(mix.T)).float()  # channels x samples
    ref = wav.mean(0)
    mean, std = ref.mean(), ref.std()
    if std < 1e-8:
        std = torch.tensor(1.0)
    wav = (wav - mean) / std

    with torch.no_grad():
        sources = apply_model(
            model, wav[None], device=device, shifts=shifts, split=True, overlap=0.25, progress=False
        )[0]
    sources = sources * std + mean
    out = {name: sources[model.sources.index(name)].cpu().numpy().T.copy() for name in STEMS}

    if device.startswith("cuda"):
        torch.cuda.empty_cache()
    elif device == "mps":
        torch.mps.empty_cache()
    return out


def refine_electronic_stems(stems: dict[str, np.ndarray], sample_rate: int) -> dict[str, np.ndarray]:
    """The electronic-style cleanup for four tracks: what refine_electronic moves out
    of the drums goes to bass below 200 Hz (sub and reese bass) and to other above
    (synths, stabs). The four tracks still add up to the same mix."""
    from scipy.signal import butter, sosfiltfilt

    rest = stems["bass"] + stems["vocals"] + stems["other"]
    kept, _ = refine_electronic(stems["drums"], rest, sample_rate)
    moved = stems["drums"] - kept
    low = sosfiltfilt(butter(4, 200, "lowpass", fs=sample_rate, output="sos"), moved, axis=0).astype(np.float32)
    return {
        "drums": kept,
        "bass": stems["bass"] + low,
        "vocals": stems["vocals"],
        "other": stems["other"] + (moved - low),
    }


def refine_electronic(
    drums: np.ndarray, no_drums: np.ndarray, sample_rate: int
) -> tuple[np.ndarray, np.ndarray]:
    """Moves sustained, pitched sound from the drums stem into no_drums.

    On electronic music (DnB, EDM) Demucs puts most of the sub bass, reese bass and
    synth stabs into "drums". A harmonic/percussive split of the drums stem keeps
    only what behaves like a hit (short, broadband) and hands the rest back. Below
    200 Hz a kick and a bass note share the same bins, so there a bin counts as a
    hit only when it stands out from its own recent past.

    drums + no_drums is unchanged, so the stems still add up to the mix.
    """
    from scipy.ndimage import median_filter
    from scipy.signal import istft, stft

    nfft, hop = 4096, 1024
    kw = dict(fs=sample_rate, nperseg=nfft, noverlap=nfft - hop)

    # One mask from the mid signal, applied to both channels, keeps the stereo image intact.
    freqs, _, spec = stft(drums.mean(axis=1), **kw)
    mag = np.abs(spec).astype(np.float32)
    del spec
    sustained = median_filter(mag, size=(1, 17), mode="nearest")  # ~0.4 s across time
    hits = median_filter(mag, size=(31, 1), mode="nearest")  # ~330 Hz across frequency
    low = freqs < 200.0
    hits[low] = mag[low]
    sustained[low] *= 1.5  # a bass note has to be clearly weaker than the kick to stay
    hits **= 2
    mask = hits / (hits + sustained**2 + 1e-12)
    del mag, sustained, hits

    kept = np.empty_like(drums)
    for ch in range(drums.shape[1]):
        _, _, spec = stft(drums[:, ch], **kw)
        _, y = istft(spec * mask, **kw)
        n = min(len(y), len(drums))
        kept[:n, ch] = y[:n]
        kept[n:, ch] = 0.0
    return kept, no_drums + (drums - kept)


def drum_share(drums: np.ndarray, no_drums: np.ndarray) -> float:
    """Fraction of the mix energy that ended up in the drums stem (0..1)."""
    d, n = float(np.square(drums, dtype=np.float64).sum()), float(np.square(no_drums, dtype=np.float64).sum())
    return round(d / (d + n), 3) if d + n > 0 else 0.0
