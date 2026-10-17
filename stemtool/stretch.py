"""Time stretching: a song's stems at another speed, same pitch. Rendered once with
ffmpeg and kept in the library's hidden work folder (which sync clients ignore)."""

from __future__ import annotations

import os
import subprocess
import uuid
from functools import lru_cache
from pathlib import Path

from .config import WORK_DIR_NAME

MIN_RATE, MAX_RATE = 0.5, 1.25


class StretchError(RuntimeError):
    pass


@lru_cache(maxsize=1)
def _filter() -> str:
    """Rubberband sounds better when this ffmpeg has it; atempo is always there."""
    try:
        out = subprocess.run(["ffmpeg", "-hide_banner", "-filters"], capture_output=True, text=True,
                             encoding="utf-8", errors="replace", timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return "atempo"
    return "rubberband" if " rubberband " in out else "atempo"


def _spec(rate: float) -> str:
    if _filter() == "rubberband":
        return f"rubberband=tempo={rate:.4f}:pitchq=quality"
    return f"atempo={rate:.4f}"


def rendered(library_dir: Path, folder: str, stem_file: Path, rate: float) -> Path:
    """The stem at `rate` (0.5 is half speed). Returns the cached file, making it first."""
    if not MIN_RATE <= rate <= MAX_RATE:
        raise StretchError(f"Speed must be between {MIN_RATE:g} and {MAX_RATE:g}")
    stat = stem_file.stat()
    tag = f"{stem_file.stem}-{round(rate * 1000)}-{stat.st_mtime_ns // 1000}.flac"
    out_dir = library_dir / WORK_DIR_NAME / "stretch" / folder
    out = out_dir / tag
    if out.is_file():
        return out
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob(f"{stem_file.stem}-{round(rate * 1000)}-*.flac"):  # the stem changed
        old.unlink(missing_ok=True)
    tmp = out_dir / f".{uuid.uuid4().hex}.flac"
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", str(stem_file),
           "-vn", "-af", _spec(rate), "-c:a", "flac", str(tmp)]
    try:
        run = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
        if run.returncode != 0:
            raise StretchError(f"ffmpeg could not change the speed: {run.stderr.strip()[-300:]}")
        os.replace(tmp, out)
    finally:
        tmp.unlink(missing_ok=True)
    return out
