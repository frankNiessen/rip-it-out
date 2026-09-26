"""Songs from your own audio files (bought music, your band's recordings, a file
from your teacher) instead of YouTube.

A file's id is a hash of its content, so importing the same file again is
recognized like a YouTube video that is already in the library.
"""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from pathlib import Path

# What ffmpeg decodes; video files contribute their sound.
EXTENSIONS = {".mp3", ".wav", ".flac", ".m4a", ".aac", ".ogg", ".opus", ".aif", ".aiff", ".wma",
              ".mp4", ".mov", ".m4v", ".mkv", ".webm"}


def file_id(path: Path) -> str:
    digest = hashlib.sha1()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return "file-" + digest.hexdigest()[:11]


def safe_name(name: str) -> str:
    """The file name without folders or odd characters, for storing the upload."""
    base = Path(name).name
    clean = re.sub(r"[^\w .()\-]+", "_", base).strip()
    stem, ext = Path(clean).stem[:100].strip(), Path(clean).suffix[:10]  # short, for Windows' path limit
    return f"{stem}{ext}" if stem else "audio"


def read_meta(path: Path, original_name: str) -> dict:
    """Title and artist from the file's tags, else from a name like "Artist - Title.mp3"."""
    tags: dict[str, str] = {}
    run = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format_tags", "-of", "json", str(path)],
                         capture_output=True, text=True, encoding="utf-8", errors="replace")
    if run.returncode == 0:
        raw = json.loads(run.stdout or "{}").get("format", {}).get("tags", {})
        tags = {k.lower(): str(v).strip() for k, v in raw.items() if str(v).strip()}
    stem = Path(original_name).stem
    name_artist, name_title = (stem.split(" - ", 1) + [""])[:2] if " - " in stem else ("", stem)
    title = tags.get("title") or name_title.strip() or stem
    artist = tags.get("artist") or tags.get("album_artist") or name_artist.strip() or None
    return {"title": title, "artist": artist, "youtube_title": None, "channel": None, "source_file": original_name}
