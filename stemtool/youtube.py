"""YouTube access via yt-dlp: expand a playlist (or single video) and download audio."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

from yt_dlp import YoutubeDL

UNAVAILABLE_TITLES = {"[Private video]", "[Deleted video]"}

# The app only takes YouTube links. yt-dlp supports many other sites, which is
# outside what this app is for, so anything else is refused before yt-dlp sees it.
YOUTUBE_HOSTS = {
    "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
    "youtu.be", "www.youtube-nocookie.com", "youtube-nocookie.com",
}


def is_youtube_url(url: str) -> bool:
    try:
        parsed = urlparse(url.strip())
    except ValueError:
        return False
    return parsed.scheme in ("http", "https") and (parsed.hostname or "").lower() in YOUTUBE_HOSTS


@dataclass(frozen=True)
class VideoRef:
    video_id: str
    title: str
    url: str
    file: str = ""  # an imported audio file instead of a YouTube video (see localfiles.py)


def watch_url(video_id: str) -> str:
    return f"https://www.youtube.com/watch?v={video_id}"


def expand(url: str) -> tuple[str, list[VideoRef]]:
    """Return (playlist title, videos) for a playlist URL, or ("", [video]) for a
    video URL.

    Only lists entries (no download), so this is quick even for long playlists.
    """
    if not is_youtube_url(url):
        raise ValueError("Only YouTube links are supported")
    opts = {"extract_flat": "in_playlist", "quiet": True, "no_warnings": True, "skip_download": True}
    with YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=False)

    entries = info.get("entries")
    if entries is None:  # a single video
        return "", [VideoRef(info["id"], info.get("title") or info["id"], watch_url(info["id"]))]

    refs: list[VideoRef] = []
    seen: set[str] = set()
    for entry in entries:
        if not entry:
            continue
        video_id = entry.get("id")
        title = entry.get("title") or video_id
        ie_key = entry.get("ie_key")
        if not video_id or video_id in seen or title in UNAVAILABLE_TITLES:
            continue
        if ie_key not in (None, "Youtube"):  # nested playlists, channel tabs, etc.
            continue
        seen.add(video_id)
        refs.append(VideoRef(video_id, title, watch_url(video_id)))
    return info.get("title") or "", refs


def download_audio(ref: VideoRef, dest_dir: Path) -> tuple[Path, dict]:
    """Download the best audio stream into dest_dir. Returns (file, metadata)."""
    opts = {
        "format": "bestaudio/best",
        "outtmpl": str(dest_dir / "download.%(ext)s"),
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
    }
    with YoutubeDL(opts) as ydl:
        info = ydl.extract_info(ref.url, download=True)

    files = [p for p in dest_dir.glob("download.*") if not p.name.endswith(".part")]
    if not files:
        raise RuntimeError("yt-dlp finished but no audio file was written")

    artists = info.get("artists")
    artist = ", ".join(artists) if artists else (info.get("artist") or info.get("creator"))
    channel = info.get("channel") or info.get("uploader")
    meta = {
        "title": info.get("track") or info.get("title") or ref.title,
        "artist": artist or channel,
        "youtube_title": info.get("title") or ref.title,
        "channel": channel,
    }
    return files[0], meta
