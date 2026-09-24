"""The library is just folders on disk. A folder counts as a song only once it
contains manifest.json, which is written last and moved into place atomically."""

from __future__ import annotations

import json
import os
import re
import threading
import unicodedata
from pathlib import Path
from typing import Iterator

MANIFEST = "manifest.json"
SCHEMA_VERSION = 1
TAKES_DIR = "takes"


def iter_manifests(library_dir: Path) -> Iterator[tuple[Path, dict]]:
    if not library_dir.is_dir():
        return
    for folder in sorted(library_dir.iterdir()):
        if not folder.is_dir() or folder.name.startswith("."):
            continue
        manifest_path = folder / MANIFEST
        if not manifest_path.is_file():
            continue
        try:
            yield folder, json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue  # half-synced or broken; ignore rather than crash the listing


def known_video_ids(library_dir: Path) -> set[str]:
    return {m["video_id"] for _, m in iter_manifests(library_dir) if m.get("video_id")}


def list_songs(library_dir: Path) -> list[dict]:
    songs = []
    for folder, m in iter_manifests(library_dir):
        processing = m.get("processing", {})
        takes = folder / TAKES_DIR
        songs.append(
            {
                "folder": folder.name,
                "video_id": m.get("video_id"),
                "title": m.get("title") or folder.name,
                "artist": m.get("artist"),
                "group": m.get("group") or "",
                "bpm": m.get("bpm"),
                "duration_s": m.get("duration_s"),
                "created_at": m.get("created_at"),
                "style": processing.get("style", "standard"),
                "drum_share": processing.get("drum_share", _estimated_drum_share(folder, m)),
                "takes": sum(1 for t in takes.glob("*/take.json")) if takes.is_dir() else 0,
                "stems": m.get("stems", {}),
                "click": m.get("click", {}),
            }
        )
    songs.sort(key=lambda s: s.get("created_at") or "", reverse=True)
    return songs


def song_dir(library_dir: Path, folder: str) -> Path | None:
    """The song folder, or None if it isn't a song inside the library."""
    path = (library_dir / folder).resolve()
    if path.parent != library_dir or folder.startswith(".") or not (path / MANIFEST).is_file():
        return None
    return path


def read_manifest(library_dir: Path, folder: str) -> dict | None:
    path = song_dir(library_dir, folder)
    return json.loads((path / MANIFEST).read_text(encoding="utf-8")) if path else None


def write_json_atomic(path: Path, data: dict) -> None:
    """Write via a hidden temp file and rename, so a reader (or Nextcloud) never
    sees a half-written file."""
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def update_manifest(song: Path, change) -> dict:
    """Read, change (in place) and atomically rewrite a song's manifest."""
    with manifest_lock:
        manifest = json.loads((song / MANIFEST).read_text(encoding="utf-8"))
        change(manifest)
        write_json_atomic(song / MANIFEST, manifest)
    return manifest


def set_group(library_dir: Path, folder: str, group: str) -> bool:
    path = song_dir(library_dir, folder)
    if not path:
        return False
    update_manifest(path, lambda m: m.__setitem__("group", group.strip()))
    return True


manifest_lock = threading.Lock()
_share_cache: dict[tuple[str, float], float | None] = {}


def _estimated_drum_share(folder: Path, manifest: dict) -> float | None:
    """For songs made before drum_share was stored: estimate it from 20 s in the
    middle of the stems. Cached per folder and manifest time, so it runs once."""
    try:
        key = (folder.name, (folder / MANIFEST).stat().st_mtime)
    except OSError:
        return None
    if key not in _share_cache:
        _share_cache[key] = _measure_share(folder, manifest)
    return _share_cache[key]


def _measure_share(folder: Path, manifest: dict) -> float | None:
    import numpy as np
    import soundfile as sf

    stems = manifest.get("stems", {})
    try:
        total = sf.info(str(folder / stems["drums"])).frames
        start, frames = max(0, total // 2 - 441000), 882000
        d, _ = sf.read(str(folder / stems["drums"]), start=start, frames=frames, dtype="float32")
        n, _ = sf.read(str(folder / stems["no_drums"]), start=start, frames=frames, dtype="float32")
    except (KeyError, OSError, RuntimeError):
        return None
    ed, en = float(np.square(d).sum()), float(np.square(n).sum())
    return round(ed / (ed + en), 3) if ed + en > 0 else None


def slugify(text: str, max_len: int = 60) -> str:
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    text = re.sub(r"[^a-zA-Z0-9]+", "-", text).strip("-").lower()
    return text[:max_len].rstrip("-")


def folder_name(title: str, video_id: str) -> str:
    # The video id suffix keeps names unique and makes the folder traceable.
    return f"{slugify(title) or 'song'}__{video_id}"
