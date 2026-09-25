"""Song sections (intro, verse, chorus, ...) for jumping and looping.

The model (stemtool/structure, All-In-One) finds the sections from the four
separated tracks. Here its output becomes what the app shows: silence before and
after the music joins its neighbour, consecutive parts with the same label are
merged, borders snap to the nearest bar line, and parts that occur more than once
are numbered (Verse 1, Verse 2).
"""

from __future__ import annotations

import numpy as np

NAMES = {"intro": "Intro", "verse": "Verse", "chorus": "Chorus", "bridge": "Bridge", "inst": "Instrumental",
         "solo": "Solo", "break": "Break", "outro": "Outro"}
MIN_SECONDS = 2.0  # shorter pieces (after snapping) join their neighbour


def detect(stems: dict[str, np.ndarray], sample_rate: int, downbeats: list[float], duration: float) -> list[dict]:
    """Sections for a song, from its four separated tracks."""
    from . import structure

    return from_segments(structure.segments(stems, sample_rate), downbeats, duration)


def from_segments(segments: list[dict], downbeats: list[float], duration: float) -> list[dict]:
    """[{"start", "end", "label", "bar"}] from the model's segments."""
    parts = [dict(s) for s in segments if s["end"] > s["start"]]
    # the silence before and after the music belongs to the first and last part
    parts = [p for p in parts if p["label"] not in ("start", "end")] or [{"start": 0.0, "end": duration, "label": "verse"}]
    parts[0]["start"], parts[-1]["end"] = 0.0, duration

    merged: list[dict] = []
    for p in parts:
        if merged and merged[-1]["label"] == p["label"]:
            merged[-1]["end"] = p["end"]
        else:
            merged.append(p)

    snapped = snap([{"start": p["start"], "end": p["end"], "label": p["label"]} for p in merged], downbeats, duration)
    cleaned: list[dict] = []
    for p in snapped:
        if cleaned and (p["end"] - p["start"] < MIN_SECONDS or cleaned[-1]["label"] == p["label"]):
            cleaned[-1]["end"] = p["end"]
        else:
            cleaned.append(p)

    counts = {p["label"]: sum(q["label"] == p["label"] for q in cleaned) for p in cleaned}
    seen: dict[str, int] = {}
    for p in cleaned:
        base = NAMES.get(p["label"], p["label"].title())
        seen[p["label"]] = seen.get(p["label"], 0) + 1
        p["kind"] = p["label"]
        p["label"] = f"{base} {seen[p['label']]}" if counts[p["label"]] > 1 else base
    return cleaned


def snap(sections: list[dict], downbeats: list[float], duration: float) -> list[dict]:
    """Move section borders to the nearest bar line (also after the beat grid changed)."""
    if not sections:
        return sections
    db = np.asarray(downbeats, dtype=float)
    out = []
    for sec in sections:
        new = dict(sec)
        if sec["start"] > 0 and len(db):
            i = int(np.abs(db - sec["start"]).argmin())
            new["start"] = round(float(db[i]), 3)
        new["start"] = 0.0 if sec["start"] <= 0 else new["start"]
        out.append(new)
    for a, b in zip(out, out[1:]):
        a["end"] = b["start"]
    out[-1]["end"] = round(duration, 3)
    out = [s for s in out if s["end"] > s["start"]]
    for s in out:
        s["bar"] = int(np.searchsorted(db, s["start"] + 0.02)) if s["start"] > 0 else 1
        s["start"], s["end"] = round(s["start"], 3), round(s["end"], 3)
    return out
