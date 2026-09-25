"""Cleaning and editing the beat grid.

beat_this follows the music closely, which is right for songs whose tempo drifts,
but it also jumps between metrical levels (a DnB song tracked at 176 bpm switches to
88 for a few bars, a beat goes missing, an extra one appears). Those jumps break the
click, the bar numbers and the count-in.

`clean` keeps the tracker's timing but commits to one metrical level for the whole
song: every tracked beat gets an integer beat number on that level, gaps are filled
and extra beats dropped, and the beats are rebuilt from a short local fit, so real
tempo drift stays. Downbeats are then placed every `beats_per_bar` beats; the bar
phase only changes when the tracker insists on the new phase for several bars.

The tracker's raw output stays in the manifest (`beats_raw`, `downbeats_raw`), so
the grid can always be cleaned again or reset.
"""

from __future__ import annotations

import numpy as np

from .beats import beats_per_bar

WIDE_HALF_WINDOW = 8  # where the tracked beats wobble (breakdowns, intros), a steadier fit
WOBBLE_SPAN = 3  # beats on each side when judging wobble
WOBBLE = 0.06  # typical change in beat length from one beat to the next, as a share of a beat
PHASE_CHANGE_BARS = 8  # the bar phase changes only if the tracker agrees this many times in a row


def number_beats(beats: np.ndarray, period: float) -> tuple[np.ndarray, np.ndarray]:
    """Integer beat numbers on the metrical level of `period`, for the beats that are
    kept. Returns (kept times, their numbers).

    A tracked beat is kept only if it lands near a whole number of beats after the
    last kept one. Off-grid hits (an off-beat, a dotted rhythm the tracker followed,
    a stretch in double time) are skipped; missing beats are filled in later.
    """
    kept_t, kept_n = [beats[0]], [0]
    local = period
    recent: list[float] = []
    raw_gaps = np.diff(beats)
    for i, t in enumerate(beats[1:]):
        # A real tempo change (an intro or bridge at another tempo): from this beat on the
        # tracker shows a steady pulse on the same metrical level. Follow it right away.
        steady = raw_gaps[i:i + 4]
        if len(steady) == 4 and steady.max() / steady.min() < 1.08:
            m = float(np.median(steady))
            if 0.7 * period < m < 1.4 * period and abs(m / local - 1) > 0.08:
                local, recent = m, [m]
        ratio = (t - kept_t[-1]) / local
        k = int(round(ratio))
        if k < 1 or (abs(ratio - k) > 0.25 and ratio < 3.5):
            continue  # off the grid; after a long stretch of those, take the next beat anyway
        k = max(k, 1)
        kept_t.append(t)
        kept_n.append(kept_n[-1] + k)
        if abs(ratio - k) < 0.12:  # only clean gaps may move the tempo
            recent = (recent + [(t - kept_t[-2]) / k])[-8:]
            # follow slow drift, but never drift to another metrical level
            local = float(np.clip(np.median(recent), period * 0.7, period * 1.4))
    return np.asarray(kept_t), np.asarray(kept_n)


def _fit(uniq: np.ndarray, times: np.ndarray, target: int, half: int) -> float:
    """Local linear fit of time over beat number around `target`."""
    lo = np.searchsorted(uniq, target - half)
    hi = np.searchsorted(uniq, target + half, side="right")
    x, y = uniq[lo:hi].astype(float), times[lo:hi]
    if len(x) < 2:  # a long break without tracked beats: use the nearest ones around it
        j = int(np.clip(np.searchsorted(uniq, target), 1, len(uniq) - 1))
        x, y = uniq[j - 1:j + 1].astype(float), times[j - 1:j + 1]
    slope, intercept = np.polyfit(x, y, 1)
    return float(slope * target + intercept)


def _wobbly(times: np.ndarray, numbers: np.ndarray, period: float) -> np.ndarray:
    """Per kept beat: do the tracked beats around it jitter back and forth? A tempo
    change is one step in the beat length; wobble is many steps in a row."""
    per_beat = np.diff(times) / np.diff(numbers)  # beat length between kept beats
    steps = np.abs(np.diff(per_beat)) / period
    padded = np.concatenate([[0.0], steps, [0.0]])  # one value per kept beat
    out = np.zeros(len(times), dtype=bool)
    for j in range(len(times)):
        window = padded[max(0, j - WOBBLE_SPAN):j + WOBBLE_SPAN + 1]
        out[j] = float(np.median(window)) > WOBBLE
    return out


def rebuild(times: np.ndarray, numbers: np.ndarray, period: float) -> np.ndarray:
    """One beat per integer number. Tracked beats are kept as they are, missing ones
    are spaced evenly between their neighbours, and where the tracked beats wobble
    (breakdowns, intros without a clear beat) a steadier local fit takes over."""
    wobbly = _wobbly(times, numbers, period) if len(times) > 2 else np.zeros(len(times), bool)
    targets = np.arange(int(numbers[0]), int(numbers[-1]) + 1)
    out = np.interp(targets, numbers, times)  # kept beats exactly, gaps filled evenly
    for k, target in enumerate(targets):
        j = int(np.clip(np.searchsorted(numbers, target), 0, len(numbers) - 1))
        if wobbly[j] or (j > 0 and wobbly[j - 1]):
            out[k] = _fit(numbers, times, int(target), WIDE_HALF_WINDOW)
    return np.maximum.accumulate(out)


def place_downbeats(beats: np.ndarray, raw_downbeats: np.ndarray, bpb: int) -> np.ndarray:
    """Downbeats every `bpb` beats, with the phase the tracker votes for."""
    if len(beats) < bpb or len(raw_downbeats) == 0:
        return beats[::bpb].copy()
    idx = np.clip(np.searchsorted(beats, raw_downbeats), 1, len(beats) - 1)
    nearest = np.where(np.abs(beats[idx - 1] - raw_downbeats) < np.abs(beats[idx] - raw_downbeats), idx - 1, idx)
    phases = nearest % bpb

    # Majority phase at the start, then change only when a new phase holds long enough.
    current = int(np.bincount(phases[: PHASE_CHANGE_BARS * 2], minlength=bpb).argmax())
    changes = [(0, current)]
    run_phase, run_len, run_start = None, 0, 0
    for beat_index, phase in zip(nearest, phases):
        if phase == current:
            run_phase, run_len = None, 0
            continue
        if phase == run_phase:
            run_len += 1
        else:
            run_phase, run_len, run_start = int(phase), 1, int(beat_index)
        if run_len >= PHASE_CHANGE_BARS:
            current = run_phase
            changes.append((run_start, current))
            run_phase, run_len = None, 0

    downbeats = []
    for (start, phase), (end, _) in zip(changes, changes[1:] + [(len(beats), None)]):
        first = start + ((phase - start) % bpb)
        downbeats.extend(range(first, end, bpb))
    return beats[np.asarray(sorted(set(downbeats)), dtype=int)]


def clean(beats: list[float], downbeats: list[float]) -> tuple[list[float], list[float], int]:
    """Returns (beats, downbeats, beats_per_bar) on one consistent metrical level."""
    b = np.asarray(beats, dtype=float)
    if len(b) < 8:
        return list(beats), list(downbeats), beats_per_bar(beats, downbeats)
    period = float(np.median(np.diff(b)))
    rebuilt = rebuild(*number_beats(b, period), period)
    bpb = beats_per_bar(beats, downbeats)
    db = place_downbeats(rebuilt, np.asarray(downbeats, dtype=float), bpb)
    return _round(rebuilt), _round(db), bpb


def _bars_from(b: np.ndarray, first: int, bpb: int) -> list[float]:
    return _round(b[first % bpb::bpb]) if len(b) else []


def _first_downbeat_index(b: np.ndarray, downbeats: list[float]) -> int:
    return int(np.searchsorted(b, downbeats[0] - 1e-3)) if len(downbeats) else 0


def shift_downbeats(beats: list[float], downbeats: list[float], steps: int, bpb: int) -> list[float]:
    """Move every bar line by `steps` beats (for when the "1" sits on the wrong beat)."""
    b = np.asarray(beats)
    return _bars_from(b, _first_downbeat_index(b, downbeats) + steps, bpb)


def double_tempo(beats: list[float], downbeats: list[float], bpb: int) -> tuple[list[float], list[float]]:
    """The tracker counted half time: a beat between every two, bars of bpb new beats."""
    b = np.asarray(beats)
    first = _first_downbeat_index(b, downbeats) * 2
    doubled = np.sort(np.concatenate([b, (b[:-1] + b[1:]) / 2]))
    return _round(doubled), _bars_from(doubled, first, bpb)


def halve_tempo(beats: list[float], downbeats: list[float], bpb: int) -> tuple[list[float], list[float]]:
    """The tracker counted double time: every other beat, keeping the bar lines' beats."""
    b = np.asarray(beats)
    first = _first_downbeat_index(b, downbeats)
    halved = b[first % 2::2]
    return _round(halved), _bars_from(halved, (first - first % 2) // 2, bpb)


def uneven_fraction(beats: list[float], downbeats: list[float]) -> float:
    """Share of bars whose beat count differs from the song's usual one (0..1)."""
    if len(downbeats) < 3:
        return 0.0
    b = np.asarray(beats)
    starts = np.searchsorted(b, np.asarray(downbeats) - 0.03)
    counts = np.diff(starts)
    if not len(counts):
        return 0.0
    values, freq = np.unique(counts, return_counts=True)
    return round(float(1 - freq.max() / len(counts)), 3)


def _round(a) -> list[float]:
    return [round(float(x), 4) for x in a]
