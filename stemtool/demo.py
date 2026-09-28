"""The demo song: "Big Rock" by Kevin MacLeod (incompetech.com), licensed under
Creative Commons Attribution 4.0. It ships ready-made (four tracks, click, beats and
sections, made with htdemucs_ft), so a new library has something to play at once,
even without a GPU or an internet connection."""

from __future__ import annotations

import shutil
from pathlib import Path

from . import config, library

DEMO_DIR = Path(__file__).parent / "demo"
CONFIG_KEY = "demo_added"


def add_to(library_dir: Path) -> bool:
    """Copies the demo song into an empty library, the first time the app starts.
    Only once: a library that already has songs doesn't get it, and a deleted demo
    stays deleted. Returns True if it was added."""
    if config.read_config().get(CONFIG_KEY):
        return False
    if next(library.iter_manifests(library_dir), None) is not None:
        config.write_config({CONFIG_KEY: True})
        return False
    added = False
    for song in sorted(DEMO_DIR.glob(f"*/{library.MANIFEST}")):
        final = library_dir / song.parent.name
        if final.exists():
            continue
        # Copied under the work folder, then moved in whole: never half a song.
        tmp = library_dir / config.WORK_DIR_NAME / f"demo-{song.parent.name}"
        shutil.rmtree(tmp, ignore_errors=True)
        shutil.copytree(song.parent, tmp)
        tmp.rename(final)
        added = True
    config.write_config({CONFIG_KEY: True})  # after the copy: a failed one is tried again
    return added
