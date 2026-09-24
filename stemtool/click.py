"""Render a click track (audio and MIDI) from beat timestamps.

The click follows the tracked beats, not a fixed BPM, so it stays with the band
when the tempo drifts.
"""

from __future__ import annotations

from pathlib import Path

import mido
import numpy as np

DOWNBEAT_TOLERANCE_S = 0.03


def _tick(freq: float, sample_rate: int, duration: float = 0.035) -> np.ndarray:
    t = np.arange(int(sample_rate * duration)) / sample_rate
    envelope = np.exp(-t * 90.0)
    return (np.sin(2 * np.pi * freq * t) * envelope).astype(np.float32)


def _downbeat_flags(beats: list[float], downbeats: list[float]) -> list[bool]:
    if not downbeats:
        return [False] * len(beats)
    db = np.asarray(downbeats)
    return [bool(np.min(np.abs(db - b)) < DOWNBEAT_TOLERANCE_S) for b in beats]


def render_audio(
    beats: list[float], downbeats: list[float], n_samples: int, sample_rate: int, gain: float = 0.6
) -> np.ndarray:
    """Returns an n_samples x 2 array, exactly as long as the stems."""
    high, low = _tick(1760.0, sample_rate), _tick(1100.0, sample_rate)
    out = np.zeros(n_samples, dtype=np.float32)
    for beat, is_down in zip(beats, _downbeat_flags(beats, downbeats)):
        start = int(round(beat * sample_rate))
        if start < 0 or start >= n_samples:
            continue
        tick = high if is_down else low
        end = min(n_samples, start + len(tick))
        out[start:end] += tick[: end - start] * gain
    return np.stack([out, out], axis=1)


def write_midi(path: Path, beats: list[float], downbeats: list[float]) -> None:
    """General MIDI percussion (channel 10): hi wood block on downbeats, low otherwise.

    Tempo is fixed at 120 BPM in the file; the note positions carry the real timing.
    """
    ticks_per_beat = 480
    ticks_per_second = ticks_per_beat * 2  # 120 BPM
    note_len = int(0.05 * ticks_per_second)

    events: list[tuple[int, mido.Message]] = []
    for beat, is_down in zip(beats, _downbeat_flags(beats, downbeats)):
        tick = int(round(beat * ticks_per_second))
        note, velocity = (76, 110) if is_down else (77, 90)
        events.append((tick, mido.Message("note_on", channel=9, note=note, velocity=velocity)))
        events.append((tick + note_len, mido.Message("note_off", channel=9, note=note, velocity=0)))
    events.sort(key=lambda e: (e[0], e[1].type == "note_on"))  # offs before ons at same tick

    mid = mido.MidiFile(ticks_per_beat=ticks_per_beat)
    track = mido.MidiTrack()
    mid.tracks.append(track)
    track.append(mido.MetaMessage("set_tempo", tempo=500_000, time=0))
    last = 0
    for tick, msg in events:
        track.append(msg.copy(time=tick - last))
        last = tick
    track.append(mido.MetaMessage("end_of_track", time=0))
    mid.save(str(path))
