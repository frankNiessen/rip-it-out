"""Recorded takes land on the song timeline at the right sample."""

import json

import numpy as np
import soundfile as sf

from stemtool import takes

from .conftest import SR


def record(tmp_path, song, capture_start_s, latency_ms, rate=48000):
    """A fake capture: the song's drums, heard late by `latency_ms`, recorded at `rate`."""
    from scipy.signal import resample_poly

    drums, _ = sf.read(str(song / "drums.flac"), dtype="float32")
    start = int((capture_start_s - latency_ms / 1000) * SR)
    seg = drums[start:start + 4 * SR]
    raw = resample_poly(seg, 160, 147, axis=0).astype(np.float32) if rate == 48000 else seg
    path = tmp_path / "capture.wav"
    sf.write(str(path), raw, rate, subtype="FLOAT")
    return path


def test_take_is_aligned_to_the_song(tmp_path, song):
    work = tmp_path / "work"
    raw = record(tmp_path, song, capture_start_s=3.0, latency_ms=30)
    take = takes.create(song, work, {"capture_start_s": 3.0, "latency_ms": 30}, raw, None, None)
    mine, _ = sf.read(str(song / "takes" / take["id"] / "my_drums.flac"), dtype="float32")
    drums, _ = sf.read(str(song / "drums.flac"), dtype="float32")
    assert len(mine) == len(drums)
    a, b = int(3.5 * SR), int(6 * SR)
    lag = np.argmax(np.correlate(mine[a:b, 0], drums[a - 200:b + 200, 0], mode="valid")) - 200
    assert abs(lag) <= 1  # within a sample
    assert json.loads((song / "takes" / take["id"] / "take.json").read_text())["start_s"] == 2.97


def test_changing_the_latency_moves_the_take(tmp_path, song):
    raw = record(tmp_path, song, capture_start_s=3.0, latency_ms=30)
    take = takes.create(song, tmp_path / "work", {"capture_start_s": 3.0, "latency_ms": 10}, raw, None, None)
    updated = takes.update(song, take["id"], {"latency_ms": 30})
    assert updated["start_s"] == 2.97


def test_export_audio_covers_the_recorded_range(tmp_path, song):
    raw = record(tmp_path, song, capture_start_s=3.0, latency_ms=0)
    take = takes.create(song, tmp_path / "work", {"capture_start_s": 3.0, "latency_ms": 0}, raw, None, None)
    result = takes.export(song, take["id"], {"my_drums": 1, "bass": 1, "vocals": 1, "other": 1}, with_video=False)
    info = sf.info(str(song / "takes" / take["id"] / result["audio"]))
    assert abs(info.duration - 4.0) < 0.01


def test_export_range_is_cut_to_the_take(tmp_path, song):
    raw = record(tmp_path, song, capture_start_s=3.0, latency_ms=0)
    take = takes.create(song, tmp_path / "work", {"capture_start_s": 3.0, "latency_ms": 0}, raw, None, None)
    result = takes.export(song, take["id"], {"my_drums": 1}, with_video=False, start_s=4.0, end_s=20.0)
    info = sf.info(str(song / "takes" / take["id"] / result["audio"]))
    assert abs(info.duration - 3.0) < 0.01  # 4.0 to the take's end at 7.0
