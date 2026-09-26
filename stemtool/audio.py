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
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if result.returncode != 0:
        raise RuntimeError(f"ffmpeg could not decode the download: {result.stderr.strip()[-400:]}")


# How stems are stored. AAC keeps all tracks sample-aligned: ffmpeg records the
# encoder delay in the file (an edit list) and decoders remove it.
FORMATS = {
    "aac256": {"ext": "m4a", "label": "Compressed, AAC 256 kbps"},
    "flac16": {"ext": "flac", "subtype": "PCM_16", "label": "Lossless, 16-bit FLAC"},
    "flac24": {"ext": "flac", "subtype": "PCM_24", "label": "Lossless, 24-bit FLAC"},
}
DEFAULT_FORMAT = "aac256"


def read(path: Path) -> tuple[np.ndarray, int]:
    """Returns (samples x channels float32 array, sample_rate)."""
    if Path(path).suffix.lower() in (".m4a", ".mp4", ".aac"):
        return _decode(path)
    data, sr = sf.read(str(path), dtype="float32", always_2d=True)
    return data, sr


def read_range(path: Path, start: int, frames: int) -> np.ndarray:
    """frames samples from sample `start` (padded with silence past the end)."""
    if Path(path).suffix.lower() in (".m4a", ".mp4", ".aac"):
        data = _decode(path)[0][start:start + frames]
    else:
        data, _ = sf.read(str(path), start=start, frames=frames, dtype="float32", always_2d=True)
    if len(data) < frames:
        data = np.concatenate([data, np.zeros((frames - len(data), data.shape[1]), np.float32)])
    return data


def _decode(path: Path) -> tuple[np.ndarray, int]:
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
                            "stream=sample_rate,channels", "-of", "csv=p=0", str(path)],
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
    if probe.returncode != 0 or not probe.stdout.strip():
        raise RuntimeError(f"ffprobe could not read {Path(path).name}")
    sr, channels = (int(x) for x in probe.stdout.strip().split(",")[:2])
    run = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-f", "f32le", "-"],
                         capture_output=True)
    if run.returncode != 0:
        raise RuntimeError(f"ffmpeg could not decode {Path(path).name}")
    return np.frombuffer(run.stdout, dtype=np.float32).reshape(-1, channels).copy(), sr


def write_flac(path: Path, data: np.ndarray, sample_rate: int, subtype: str = "PCM_24") -> None:
    sf.write(str(path), np.clip(data, -1.0, 1.0), sample_rate, format="FLAC", subtype=subtype)


def write_stem(folder: Path, name: str, data: np.ndarray, sample_rate: int, fmt: str) -> str:
    """Writes folder/name.<ext> in the given format; returns the file name."""
    spec = FORMATS.get(fmt, FORMATS[DEFAULT_FORMAT])
    filename = f"{name}.{spec['ext']}"
    if spec["ext"] == "flac":
        write_flac(folder / filename, data, sample_rate, spec["subtype"])
        return filename
    tmp = folder / f".{name}.encode.wav"
    sf.write(str(tmp), np.clip(data, -1.0, 1.0), sample_rate, subtype="FLOAT")
    try:
        run = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(tmp), "-c:a", "aac",
                              "-b:a", "256k", "-movflags", "+faststart", str(folder / filename)],
                             capture_output=True, text=True, encoding="utf-8", errors="replace")
        if run.returncode != 0:
            raise RuntimeError(f"ffmpeg could not encode {filename}: {run.stderr.strip()[-300:]}")
    finally:
        tmp.unlink(missing_ok=True)
    return filename
