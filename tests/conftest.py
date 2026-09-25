"""Shared fixtures. Tests never touch a real library: each one gets a temporary
library with a generated song (noise stems, a steady 120 bpm grid)."""

from __future__ import annotations

import importlib
import json
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf

SR = 44100
SECONDS = 12
BPM = 120


def make_song(library: Path, folder: str = "test-song__abc123", video_id: str = "abc123") -> Path:
    song = library / folder
    song.mkdir(parents=True)
    n = SR * SECONDS
    rng = np.random.default_rng(0)
    drums = (rng.standard_normal((n, 2)) * 0.05).astype(np.float32)
    music = (rng.standard_normal((n, 2)) * 0.05).astype(np.float32)
    for name, data in (("drums.flac", drums), ("no_drums.flac", music), ("click.flac", np.zeros((n, 2), np.float32))):
        sf.write(str(song / name), data, SR, subtype="PCM_24")
    (song / "click.mid").write_bytes(b"")
    beats = [round(0.5 + i * 60 / BPM, 4) for i in range(int((SECONDS - 1) * BPM / 60))]
    manifest = {
        "schema": 1, "video_id": video_id, "source_url": f"https://www.youtube.com/watch?v={video_id}",
        "title": "Test Song", "artist": "Test", "group": "", "sample_rate": SR, "num_samples": n,
        "duration_s": SECONDS, "bpm": BPM, "beats_per_bar": 4, "beats": beats, "downbeats": beats[::4],
        "stems": {"drums": "drums.flac", "no_drums": "no_drums.flac"},
        "click": {"audio": "click.flac", "midi": "click.mid"},
        "processing": {"separation_model": "htdemucs_ft", "style": "standard", "stem_gain": 1.0},
    }
    (song / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return song


@pytest.fixture
def library(tmp_path: Path) -> Path:
    lib = tmp_path / "library"
    lib.mkdir()
    return lib


@pytest.fixture
def song(library: Path) -> Path:
    return make_song(library)


@pytest.fixture
def client(tmp_path: Path, library: Path, song: Path, monkeypatch):
    """The FastAPI app, configured for the temporary library."""
    from fastapi.testclient import TestClient

    config = tmp_path / "settings.json"
    config.write_text(json.dumps({"library": str(library)}))
    monkeypatch.setenv("STEMTOOL_CONFIG", str(config))
    monkeypatch.delenv("STEMTOOL_LIBRARY", raising=False)
    import stemtool.server as server

    server = importlib.reload(server)  # picks up the settings above
    with TestClient(server.app) as c:
        yield c
