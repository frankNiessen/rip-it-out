"""Recorded takes: your own drums (and optionally video) played along to a song.

A take lives in <song>/takes/<id>/ and is built in the hidden work folder first,
then renamed into place, like songs. Files:

  take.json      written last; describes timing and files
  raw.flac       the input exactly as captured (browser sample rate)
  my_drums.flac  the capture moved onto the song timeline: same sample rate and
                 sample count as the song stems, silence where you didn't play
  video.*        the camera recording as the browser made it (webm or mp4)
  export.*       the last mix you exported (wav, mp4)

Timing: the browser reports the song time at which capture started. Everything
you play reaches the capture late by the round trip latency (output to your ears,
input back from the module), so a sample captured at song time t was played at
t - latency. my_drums.flac is re-rendered when you change the latency.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import uuid
from datetime import datetime, timezone
from math import gcd
from pathlib import Path

import numpy as np
import soundfile as sf

from . import audio, library

SCHEMA_VERSION = 1
TAKE_ID = re.compile(r"^[0-9A-Za-z_-]{1,64}$")
VIDEO_EXTS = {"webm", "mp4", "mov", "mkv"}
SYNC_RATE = 8000  # sample rate used to line the video's sound up with the capture


class TakeError(Exception):
    pass


def takes_dir(song: Path) -> Path:
    return song / library.TAKES_DIR


def take_path(song: Path, take_id: str) -> Path | None:
    if not TAKE_ID.match(take_id):
        return None
    path = takes_dir(song) / take_id
    return path if (path / "take.json").is_file() else None


def list_takes(song: Path) -> list[dict]:
    out = []
    root = takes_dir(song)
    if root.is_dir():
        for path in root.iterdir():
            try:
                out.append(json.loads((path / "take.json").read_text(encoding="utf-8")))
            except (OSError, json.JSONDecodeError):
                continue
    out.sort(key=lambda t: t.get("created_at", ""), reverse=True)
    return out


def create(song: Path, work_root: Path, meta: dict, raw_upload: Path,
           video_upload: Path | None, video_ext: str | None) -> dict:
    manifest = json.loads((song / library.MANIFEST).read_text(encoding="utf-8"))
    now = datetime.now()
    take_id = now.strftime("%Y-%m-%d_%H-%M-%S")
    while (takes_dir(song) / take_id).exists():
        take_id += "b"

    work = work_root / f"take-{uuid.uuid4().hex[:8]}"
    work.mkdir(parents=True)
    try:
        raw, raw_sr = sf.read(str(raw_upload), dtype="float32", always_2d=True)
        if raw.shape[1] == 1:
            raw = np.repeat(raw, 2, axis=1)
        raw = raw[:, :2]
        if len(raw) < raw_sr // 2:
            raise TakeError("The recording is shorter than half a second")
        audio.write_flac(work / "raw.flac", raw, raw_sr)
        peak = float(np.abs(raw).max())

        take = {
            "schema": SCHEMA_VERSION,
            "id": take_id,
            "created_at": now.astimezone(timezone.utc).isoformat(timespec="seconds"),
            "name": "",
            "input": str(meta.get("input_label") or ""),
            "sample_rate": manifest["sample_rate"],
            "captured_sample_rate": raw_sr,
            "captured_s": round(len(raw) / raw_sr, 3),
            "capture_start_s": round(float(meta["capture_start_s"]), 5),
            "latency_ms": round(float(meta.get("latency_ms") or 0.0), 2),
            "peak_dbfs": round(20 * np.log10(max(peak, 1e-6)), 1),
            "files": {"my_drums": "my_drums.flac", "raw": "raw.flac"},
            "video": None,
        }

        if video_upload is not None and video_upload.stat().st_size > 0:
            ext = video_ext if video_ext in VIDEO_EXTS else "webm"
            video = work / f"video.{ext}"
            _remux(video_upload, video)
            offset, sync = _video_offset(video, raw, raw_sr), "audio"
            if offset is None:
                offset, sync = meta.get("video_clock_offset_s"), "clock"
            take["video"] = {
                "file": video.name,
                "start_in_capture_s": round(float(offset or 0.0), 4),
                "sync": sync,
                "nudge_ms": 0.0,
            }
        _derive(take)
        _render_aligned(work, take, manifest, raw)
        library.write_json_atomic(work / "take.json", take)

        takes_dir(song).mkdir(exist_ok=True)
        work.rename(takes_dir(song) / take_id)
        return take
    finally:
        shutil.rmtree(work, ignore_errors=True)


def update(song: Path, take_id: str, changes: dict) -> dict:
    path = take_path(song, take_id)
    if path is None:
        raise TakeError("Take not found")
    take = json.loads((path / "take.json").read_text(encoding="utf-8"))
    rerender = False
    if changes.get("latency_ms") is not None and float(changes["latency_ms"]) != take["latency_ms"]:
        take["latency_ms"] = round(float(changes["latency_ms"]), 2)
        rerender = True
    if changes.get("video_nudge_ms") is not None and take.get("video"):
        take["video"]["nudge_ms"] = round(float(changes["video_nudge_ms"]), 1)
    if changes.get("name") is not None:
        take["name"] = str(changes["name"]).strip()[:120]
    _derive(take)
    if rerender:
        manifest = json.loads((song / library.MANIFEST).read_text(encoding="utf-8"))
        raw, _ = sf.read(str(path / take["files"]["raw"]), dtype="float32", always_2d=True)
        _render_aligned(path, take, manifest, raw)
    library.write_json_atomic(path / "take.json", take)
    return take


def delete(song: Path, take_id: str) -> bool:
    path = take_path(song, take_id)
    if path is None:
        return False
    shutil.rmtree(path)
    return True


def export(song: Path, take_id: str, gains: dict, with_video: bool) -> dict:
    """Mixes the take with the song stems over the recorded range. Writes
    export.wav, and export.mp4 when asked and the take has video."""
    path = take_path(song, take_id)
    if path is None:
        raise TakeError("Take not found")
    take = json.loads((path / "take.json").read_text(encoding="utf-8"))
    manifest = json.loads((song / library.MANIFEST).read_text(encoding="utf-8"))
    sr, total = manifest["sample_rate"], manifest["num_samples"]

    a = max(0, int(round(take["start_s"] * sr)))
    b = min(total, int(round((take["start_s"] + take["captured_s"]) * sr)))
    if b - a < sr // 2:
        raise TakeError("This take doesn't overlap the song")

    # gains are keyed like the app's faders: my_drums, drums, bass, vocals, other, click
    # (and "music" for songs still in the two-track layout, whose stem is no_drums)
    sources = {"my_drums": path / take["files"]["my_drums"], "click": song / manifest["click"]["audio"]}
    for name, filename in manifest["stems"].items():
        sources["music" if name == "no_drums" else name] = song / filename
    mix = np.zeros((b - a, 2), dtype=np.float32)
    for key, file in sources.items():
        g = float(gains.get(key, 0.0))
        if g > 0:
            data = audio.read_range(file, a, b - a)
            mix += data[:, :2] * g
    peak = float(np.abs(mix).max())
    if peak > 0.99:
        mix *= 0.99 / peak

    tmp = path / ".export.wav"
    sf.write(str(tmp), mix, sr, subtype="PCM_24")
    result = {"audio": "export.wav", "video": None}
    try:
        if with_video and take.get("video"):
            video = path / take["video"]["file"]
            start_in_video = a / sr - take["video"]["start_s"]
            cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y"]
            if start_in_video >= 0:
                cmd += ["-ss", f"{start_in_video:.4f}", "-i", str(video)]
            else:  # camera started after the recorded range: delay the picture
                cmd += ["-itsoffset", f"{-start_in_video:.4f}", "-i", str(video)]
            cmd += [
                "-i", str(tmp), "-map", "0:v:0", "-map", "1:a:0", "-t", f"{(b - a) / sr:.4f}",
                # Apple's hardware encoder: fast, and needs no GPL x264 in the packaged ffmpeg
                "-c:v", "h264_videotoolbox", "-b:v", "8M", "-allow_sw", "1", "-pix_fmt", "yuv420p",
                "-fps_mode", "cfr", "-r", "30",
                "-c:a", "aac", "-b:a", "256k", "-movflags", "+faststart", str(path / ".export.mp4"),
            ]
            run = subprocess.run(cmd, capture_output=True, text=True)
            if run.returncode != 0:
                raise TakeError(f"ffmpeg could not render the video: {run.stderr.strip()[-400:]}")
            os.replace(path / ".export.mp4", path / "export.mp4")
            result["video"] = "export.mp4"
        os.replace(tmp, path / "export.wav")
    finally:
        tmp.unlink(missing_ok=True)
        (path / ".export.mp4").unlink(missing_ok=True)
    return result


# --- internals ---------------------------------------------------------------

def _derive(take: dict) -> None:
    """Song-time fields, kept in take.json so readers (the iOS app) needn't redo the math."""
    take["start_s"] = round(take["capture_start_s"] - take["latency_ms"] / 1000.0, 5)
    if take.get("video"):
        v = take["video"]
        v["start_s"] = round(take["start_s"] + v["start_in_capture_s"] + v["nudge_ms"] / 1000.0, 5)


def _render_aligned(folder: Path, take: dict, manifest: dict, raw: np.ndarray) -> None:
    from scipy.signal import resample_poly

    sr, total = manifest["sample_rate"], manifest["num_samples"]
    raw_sr = take["captured_sample_rate"]
    if raw_sr != sr:
        g = gcd(sr, raw_sr)
        raw = resample_poly(raw, sr // g, raw_sr // g, axis=0).astype(np.float32)
    out = np.zeros((total, 2), dtype=np.float32)
    start = int(round(take["start_s"] * sr))
    src_from = max(0, -start)
    dst_from = max(0, start)
    n = min(len(raw) - src_from, total - dst_from)
    if n > 0:
        out[dst_from:dst_from + n] = raw[src_from:src_from + n]
    tmp = folder / ".my_drums.flac"
    audio.write_flac(tmp, out, sr)
    os.replace(tmp, folder / take["files"]["my_drums"])


def _remux(src: Path, dst: Path) -> None:
    """Browser recordings lack a seek index (and often a duration). A copy through
    ffmpeg adds both without re-encoding; if that fails, keep the file as it is."""
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(src),
           "-map", "0", "-c", "copy"]
    if dst.suffix in (".mp4", ".mov"):
        cmd += ["-movflags", "+faststart"]
    if subprocess.run(cmd + [str(dst)], capture_output=True).returncode != 0 or not dst.is_file():
        dst.unlink(missing_ok=True)
        shutil.move(str(src), dst)


def _video_offset(video: Path, raw: np.ndarray, raw_sr: int) -> float | None:
    """Where the video starts, in seconds from the start of the capture, found by
    lining up the sound in the video file with the captured audio (both come from
    the same input). None if the video has no usable sound."""
    from scipy.signal import correlate, correlation_lags, resample_poly

    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-i", str(video),
           "-vn", "-ac", "1", "-ar", str(SYNC_RATE), "-f", "f32le", "-"]
    run = subprocess.run(cmd, capture_output=True)
    if run.returncode != 0 or len(run.stdout) < SYNC_RATE * 4:
        return None
    v = np.frombuffer(run.stdout, dtype=np.float32)
    g = gcd(SYNC_RATE, raw_sr)
    r = resample_poly(raw.mean(axis=1), SYNC_RATE // g, raw_sr // g).astype(np.float32)
    if np.abs(v).max() < 1e-3 or np.abs(r).max() < 1e-3:
        return None

    corr = correlate(r, v, mode="full", method="fft")
    lags = correlation_lags(len(r), len(v), mode="full")
    window = np.abs(lags) <= 10 * SYNC_RATE  # the camera starts within seconds of the capture
    corr, lags = np.abs(corr[window]), lags[window]
    best = int(np.argmax(corr))
    if corr[best] < 8 * (np.median(corr) + 1e-9):  # no clear match
        return None
    return float(lags[best]) / SYNC_RATE
