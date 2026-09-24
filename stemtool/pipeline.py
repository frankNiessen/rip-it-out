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

import numpy as np

from . import audio, beats, click, library, separation, youtube
from .config import SAMPLE_RATE, Settings

StageCallback = Callable[[str], None]


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
    """Redo the separation of a song already in the library, with another style.

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
        drums, sr = audio.read(song / manifest["stems"]["drums"])
        no_drums, _ = audio.read(song / manifest["stems"]["no_drums"])
        mix = (drums + no_drums) / float(manifest.get("processing", {}).get("stem_gain") or 1.0)
        del drums, no_drums

        drums, no_drums, gain, share = _separate(mix, sr, settings, style, on_stage)
        on_stage("Writing files")
        audio.write_flac(work / "drums.flac", drums * gain, sr)
        audio.write_flac(work / "no_drums.flac", no_drums * gain, sr)
        with _no_stop():  # a Stop in here would leave stems that no longer add up
            os.replace(work / "drums.flac", song / manifest["stems"]["drums"])
            os.replace(work / "no_drums.flac", song / manifest["stems"]["no_drums"])
            library.update_manifest(song, lambda m: m.setdefault("processing", {}).update(
                separation_model=settings.separation_model, style=style,
                stem_gain=round(gain, 4), drum_share=share,
            ))
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
    """Returns (drums, no_drums, shared_gain, drum_share)."""
    on_stage("Separating drums")
    drums, no_drums = separation.separate_drums(
        mix, sr, settings.separation_model, settings.device, settings.shifts
    )
    if style == "electronic":
        on_stage("Cleaning up drums (electronic)")
        drums, no_drums = separation.refine_electronic(drums, no_drums, sr)
    # One shared gain for both stems, so drums + no_drums still add up to the mix.
    peak = float(max(np.abs(drums).max(), np.abs(no_drums).max(), 1e-9))
    gain = 0.99 / peak if peak > 0.99 else 1.0
    return drums, no_drums, gain, separation.drum_share(drums, no_drums)


def _process(ref: youtube.VideoRef, settings: Settings, on_stage: StageCallback, work: Path,
             style: str, group: str) -> Path:
    on_stage("Downloading")
    download, meta = youtube.download_audio(ref, work)

    on_stage("Decoding")
    mix_wav = work / "mix.wav"
    audio.decode_to_wav(download, mix_wav, SAMPLE_RATE)
    mix, sr = audio.read(mix_wav)

    drums, no_drums, gain, share = _separate(mix, sr, settings, style, on_stage)

    on_stage("Finding beats")
    beat_times, downbeat_times = beats.track(mix.mean(axis=1), sr, settings.beat_checkpoint, settings.device)

    on_stage("Writing files")
    song = work / "song"
    song.mkdir()
    audio.write_flac(song / "drums.flac", drums * gain, sr)
    audio.write_flac(song / "no_drums.flac", no_drums * gain, sr)
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
        "beats_per_bar": beats.beats_per_bar(beat_times, downbeat_times),
        "beats": beat_times,
        "downbeats": downbeat_times,
        "stems": {"drums": "drums.flac", "no_drums": "no_drums.flac"},
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
