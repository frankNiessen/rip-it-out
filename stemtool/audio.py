"""Audio file helpers. ffmpeg decodes whatever YouTube delivers (opus, m4a) into a
fixed-format WAV so every later step sees the same sample rate and length."""

from __future__ import annotations

import subprocess
from pathlib import Path

import numpy as np
import soundfile as sf


def decode_to_wav(src: Path, dst: Path, sample_rate: int) -> None:
    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-i", str(src), "-vn", "-ac", "2", "-ar", str(sample_rate),
        "-c:a", "pcm_f32le", str(dst),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg could not decode the download: {result.stderr.strip()[-400:]}")


def read(path: Path) -> tuple[np.ndarray, int]:
    """Returns (samples x channels float32 array, sample_rate)."""
    data, sr = sf.read(str(path), dtype="float32", always_2d=True)
    return data, sr


def write_flac(path: Path, data: np.ndarray, sample_rate: int) -> None:
    sf.write(str(path), np.clip(data, -1.0, 1.0), sample_rate, format="FLAC", subtype="PCM_24")
