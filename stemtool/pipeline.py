"""Process one video into a finished song folder.

Everything is built in a hidden work folder inside the library and renamed into
place at the end, so Nextcloud never syncs a half-written song.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import threading
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

import logging

import numpy as np

from . import audio, beats, click, grid, library, sections, separation, youtube
from .config import SAMPLE_RATE, Settings

StageCallback = Callable[[str], None]
log = logging.getLogger("stemtool")


def process(ref: youtube.VideoRef, settings: Settings, on_stage: StageCallback,
            style: str = "standard", group: str = "") -> Path:
    work = settings.work_dir / ref.video_id
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    try:
        return _process(ref, settings, on_stage, work, style, group)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def reseparate(folder: str, settings: Settings, on_stage: StageCallback, style: str) -> Path:
    """Redo the separation of a song already in the library: another style, the
    four-track layout, or another storage format.

    The mix is rebuilt from the existing stems (they add up to it), so nothing is
    downloaded again, and length, beats, click and recorded takes stay valid.
    """
    song = library.song_dir(settings.library_dir, folder)
    if song is None:
        raise RuntimeError("Song not found in the library")
    work = settings.work_dir / f"reseparate-{folder}"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    try:
        manifest = json.loads((song / library.MANIFEST).read_text(encoding="utf-8"))
        on_stage("Reading stems")
        mix = None
        for name in manifest["stems"].values():
            data, sr = audio.read(song / name)
            mix = data if mix is None else mix + data
        mix /= float(manifest.get("processing", {}).get("stem_gain") or 1.0)

        stems, gain, share = _separate(mix, sr, settings, style, on_stage)
        song_sections = _sections(stems, sr, manifest["downbeats"], manifest["duration_s"], on_stage)
        on_stage("Writing files")
        files = _write_stems(work, stems, gain, sr, settings.stem_format)
        old = set(manifest["stems"].values())
        with _no_stop():  # a Stop in here would leave stems that no longer add up
            for filename in files.values():
                os.replace(work / filename, song / filename)

            def change(m: dict) -> None:
                m["schema"] = library.SCHEMA_VERSION
                m["stems"] = files
                m["stem_format"] = settings.stem_format
                if song_sections is not None:
                    m["sections"] = song_sections
                m.setdefault("processing", {}).update(
                    separation_model=settings.separation_model, style=style,
                    stem_gain=round(gain, 4), drum_share=share,
                )
            library.update_manifest(song, change)
            for filename in old - set(files.values()):  # e.g. no_drums.flac, or drums.flac became drums.m4a
                (song / filename).unlink(missing_ok=True)
        return song
    finally:
        shutil.rmtree(work, ignore_errors=True)


@contextmanager
def _no_stop():
    """Defers SIGTERM (the queue's Stop button) until the block is done."""
    if threading.current_thread() is not threading.main_thread():
        yield
        return
    pending: list[int] = []
    previous = signal.signal(signal.SIGTERM, lambda signum, _frame: pending.append(signum))
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, previous)
        if pending:
            signal.raise_signal(signal.SIGTERM)


def _separate(mix: np.ndarray, sr: int, settings: Settings, style: str, on_stage: StageCallback):
    """Returns (stems, shared_gain, drum_share); stems: drums, bass, vocals, other."""
    on_stage("Separating")
    stems = separation.separate(mix, sr, settings.separation_model, settings.device, settings.shifts)
    if style == "electronic":
        on_stage("Cleaning up drums (electronic)")
        stems = separation.refine_electronic_stems(stems, sr)
    # One shared gain for all stems, so they still add up to the mix.
    peak = float(max(max(np.abs(x).max() for x in stems.values()), 1e-9))
    gain = 0.99 / peak if peak > 0.99 else 1.0
    rest = stems["bass"] + stems["vocals"] + stems["other"]
    return stems, gain, separation.drum_share(stems["drums"], rest)


def _write_stems(folder: Path, stems: dict[str, np.ndarray], gain: float, sr: int, fmt: str) -> dict[str, str]:
    return {name: audio.write_stem(folder, name, data * gain, sr, fmt) for name, data in stems.items()}


def _sections(stems: dict[str, np.ndarray], sr: int, downbeats: list[float], duration: float,
              on_stage: StageCallback) -> list[dict] | None:
    """The song's sections, or None if the section model isn't available (offline)."""
    on_stage("Finding sections")
    try:
        return sections.detect(stems, sr, downbeats, duration)
    except Exception as exc:  # noqa: BLE001 (sections are nice to have; the song itself is fine)
        log.warning("Sections not found: %s", exc)
        return None


def _process(ref: youtube.VideoRef, settings: Settings, on_stage: StageCallback, work: Path,
             style: str, group: str) -> Path:
    on_stage("Downloading")
    download, meta = youtube.download_audio(ref, work)

    on_stage("Decoding")
    mix_wav = work / "mix.wav"
    audio.decode_to_wav(download, mix_wav, SAMPLE_RATE)
    mix, sr = audio.read(mix_wav)

    stems, gain, share = _separate(mix, sr, settings, style, on_stage)

    on_stage("Finding beats")
    raw_beats, raw_downbeats = beats.track(mix.mean(axis=1), sr, settings.beat_checkpoint, settings.device)
    beat_times, downbeat_times, bpb = grid.clean(raw_beats, raw_downbeats)

    song_sections = _sections(stems, sr, downbeat_times, len(mix) / sr, on_stage) or []

    on_stage("Writing files")
    song = work / "song"
    song.mkdir()
    files = _write_stems(song, stems, gain, sr, settings.stem_format)
    del stems
    audio.write_flac(song / "click.flac", click.render_audio(beat_times, downbeat_times, len(mix), sr), sr)
    click.write_midi(song / "click.mid", beat_times, downbeat_times)

    manifest = {
        "schema": library.SCHEMA_VERSION,
        "video_id": ref.video_id,
        "source_url": ref.url,
        "title": meta["title"],
        "artist": meta["artist"],
        "youtube_title": meta["youtube_title"],
        "channel": meta["channel"],
        "group": group,
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sample_rate": sr,
        "num_samples": len(mix),
        "duration_s": round(len(mix) / sr, 3),
        "bpm": beats.estimate_bpm(beat_times),
        "beats_per_bar": bpb,
        "beats": beat_times,
        "downbeats": downbeat_times,
        "grid": "clean",
        "beats_raw": raw_beats,  # the tracker's output, to clean again or reset the grid
        "downbeats_raw": raw_downbeats,
        "sections": song_sections,
        "stems": files,  # drums, bass, vocals, other
        "stem_format": settings.stem_format,
        "click": {"audio": "click.flac", "midi": "click.mid"},
        "processing": {
            "separation_model": settings.separation_model,
            "style": style,
            "beat_checkpoint": settings.beat_checkpoint,
            "stem_gain": round(gain, 4),
            "drum_share": share,
        },
    }
    # Manifest last: a folder without one is never treated as a song.
    (song / library.MANIFEST).write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    final = settings.library_dir / library.folder_name(meta["title"], ref.video_id)
    if final.exists():
        raise RuntimeError(f"{final.name} already exists in the library")
    song.rename(final)
    return final


GRID_ACTIONS = ("clean", "reset", "shift", "double", "half")


def regrid(song: Path, action: str, steps: int = 1) -> dict:
    """Change a song's beat grid and re-render its click. Returns the new manifest.

    clean: rebuild from the tracker's raw output (see grid.py); reset: back to the raw
    output; shift: move the bar lines by `steps` beats; double / half: the tracker
    counted at the wrong tempo level.
    """
    manifest = json.loads((song / library.MANIFEST).read_text(encoding="utf-8"))
    raw_b = manifest.get("beats_raw", manifest["beats"])  # songs made before cleaning existed
    raw_db = manifest.get("downbeats_raw", manifest["downbeats"])
    cur_b, cur_db = manifest["beats"], manifest["downbeats"]
    bpb = int(manifest.get("beats_per_bar") or beats.beats_per_bar(cur_b, cur_db))

    if action == "clean":
        new_b, new_db, bpb = grid.clean(raw_b, raw_db)
    elif action == "reset":
        new_b, new_db, bpb = list(raw_b), list(raw_db), beats.beats_per_bar(raw_b, raw_db)
    elif action == "shift":
        new_b, new_db = cur_b, grid.shift_downbeats(cur_b, cur_db, steps, bpb)
    elif action == "double":
        new_b, new_db = grid.double_tempo(cur_b, cur_db, bpb)
    elif action == "half":
        new_b, new_db = grid.halve_tempo(cur_b, cur_db, bpb)
    else:
        raise ValueError(f"Unknown grid action {action!r}")

    sr, n = manifest["sample_rate"], manifest["num_samples"]
    tmp_audio, tmp_midi = song / ".click.flac.tmp", song / ".click.mid.tmp"
    audio.write_flac(tmp_audio, click.render_audio(new_b, new_db, n, sr), sr)
    click.write_midi(tmp_midi, new_b, new_db)
    os.replace(tmp_audio, song / manifest["click"]["audio"])
    os.replace(tmp_midi, song / manifest["click"]["midi"])

    def change(m: dict) -> None:
        m.setdefault("beats_raw", raw_b)
        m.setdefault("downbeats_raw", raw_db)
        m.update(beats=new_b, downbeats=new_db, beats_per_bar=bpb, bpm=beats.estimate_bpm(new_b),
                 grid="raw" if action == "reset" else ("clean" if action == "clean" else "edited"))
        if m.get("sections"):
            m["sections"] = sections.snap(m["sections"], new_db, m["duration_s"])
    return library.update_manifest(song, change)


def analyze_sections(song: Path) -> dict:
    """Find sections again for a four-track song already in the library."""
    manifest = json.loads((song / library.MANIFEST).read_text(encoding="utf-8"))
    if "bass" not in manifest["stems"]:
        raise RuntimeError("Sections need the four-track layout: convert the song first")
    stems = {name: audio.read(song / filename)[0] for name, filename in manifest["stems"].items()}
    found = sections.detect(stems, manifest["sample_rate"], manifest["downbeats"], manifest["duration_s"])
    return library.update_manifest(song, lambda m: m.__setitem__("sections", found))
