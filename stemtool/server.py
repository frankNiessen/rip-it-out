"""FastAPI app. Run with:  uvicorn stemtool.server:app --port 8765"""

from __future__ import annotations

import json
import logging
import os
import secrets
import shutil
import signal
import uuid
from contextlib import asynccontextmanager
from dataclasses import replace
from pathlib import Path

from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from yt_dlp.utils import DownloadError

from . import __version__, audio, config, library, localfiles, pipeline, takes, youtube
from .config import STYLES, load_settings
from .jobs import JobManager

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

settings = load_settings()
settings.library_dir.mkdir(parents=True, exist_ok=True)
manager = JobManager(settings)
STATIC = Path(__file__).parent / "static"


@asynccontextmanager
async def lifespan(_: FastAPI):
    manager.start()
    yield
    manager.stop_all()  # through the stop guard, so quitting never leaves half-written files


app = FastAPI(title="Rip It Out", lifespan=lifespan)
app.mount("/static", StaticFiles(directory=STATIC), name="static")


class SettingsUpdate(BaseModel):
    library_dir: str | None = None
    stem_format: str | None = None


class SubmitRequest(BaseModel):
    url: str
    style: str = "standard"
    group: str | None = None  # None: use the playlist title


class GroupRequest(BaseModel):
    folders: list[str]
    group: str


class GridRequest(BaseModel):
    folders: list[str]
    action: str  # clean, reset, shift, double, half
    steps: int = 1


class ReseparateRequest(BaseModel):
    folders: list[str]
    style: str


class TakeUpdate(BaseModel):
    latency_ms: float | None = None
    video_nudge_ms: float | None = None
    name: str | None = None


class TakeRef(BaseModel):
    folder: str
    take_id: str


class TakesDeleteRequest(BaseModel):
    takes: list[TakeRef]
    exports_only: bool = False  # keep the takes, remove only export.wav/mp4


class ExportRequest(BaseModel):
    gains: dict[str, float]
    video: bool = False
    start_s: float | None = None  # song time; None: from the start of the take
    end_s: float | None = None


def _song(folder: str) -> Path:
    path = library.song_dir(settings.library_dir, folder)
    if path is None:
        raise HTTPException(404, "Song not found")
    return path


@app.get("/")
def index() -> FileResponse:
    return FileResponse(STATIC / "index.html")


@app.get("/files/{path:path}")
def files(path: str) -> FileResponse:
    """Song files (stems, takes) from the current library. Supports range requests,
    so video seeking works."""
    root = settings.library_dir
    target = (root / path).resolve()
    if root not in target.parents or any(part.startswith(".") for part in Path(path).parts) or not target.is_file():
        raise HTTPException(404, "File not found")
    return FileResponse(target)


@app.get("/api/status")
def status() -> dict:
    return {
        "version": __version__,
        "library_dir": str(settings.library_dir),
        "library_locked": config.library_locked(),
        "config_file": str(config.config_file()),
        "separation_model": settings.separation_model,
        "device": settings.device_setting,
        "styles": list(STYLES),
        "stem_format": settings.stem_format,
        "formats": {key: spec["label"] for key, spec in audio.FORMATS.items()},
        "to_convert": len(_songs_to_convert()),
    }


def _songs_to_convert() -> list[dict]:
    """Songs not yet in the four-track layout, or stored in another format than the setting."""
    return [s for s in library.list_songs(settings.library_dir)
            if s["tracks"] != 4 or s["stem_format"] != settings.stem_format]


@app.put("/api/settings")
def update_settings(req: SettingsUpdate) -> dict:
    """Switch the library folder or the storage format. Takes effect immediately and is saved."""
    global settings
    if req.stem_format is not None:
        if req.stem_format not in audio.FORMATS:
            raise HTTPException(400, f"Unknown format {req.stem_format!r}")
        config.write_config({"stem_format": req.stem_format})
        settings = replace(settings, stem_format=req.stem_format)
        manager.settings = settings
    if req.library_dir is None:
        return status()
    if config.library_locked():
        raise HTTPException(409, "The library is set by the STEMTOOL_LIBRARY environment variable")
    raw = req.library_dir.strip()
    if not raw:
        raise HTTPException(400, "Choose a folder")
    new = Path(raw).expanduser()
    if not new.is_absolute():
        raise HTTPException(400, "Use a full path, like /Users/you/Music/Rip It Out")
    new = new.resolve()
    if manager.busy():
        raise HTTPException(409, "Songs are still being processed. Stop them or wait before switching.")
    try:
        new.mkdir(parents=True, exist_ok=True)
        probe = new / ".stemtool-write-test"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
    except OSError as exc:
        raise HTTPException(400, f"Can't use that folder: {exc.strerror or exc}") from exc
    config.write_config({"library": str(new)})
    settings = replace(settings, library_dir=new)
    manager.settings = settings
    return status()


@app.post("/api/submit")
def submit(req: SubmitRequest) -> dict:  # sync: runs in a threadpool, playlist listing can take a while
    url = req.url.strip()
    if not youtube.is_youtube_url(url):
        raise HTTPException(400, "Paste a YouTube video or playlist link (youtube.com or youtu.be)")
    if req.style not in STYLES:
        raise HTTPException(400, f"Unknown style {req.style!r}")
    try:
        return manager.submit(url, req.style, req.group)
    except DownloadError as exc:
        raise HTTPException(400, f"YouTube couldn't list that link: {exc}") from exc


@app.post("/api/import")
def import_files(files: list[UploadFile] = File(...), style: str = Form("standard"), group: str = Form("")) -> dict:
    """Queue your own audio or video files (drag and drop in the Library tab)."""
    if style not in STYLES:
        raise HTTPException(400, f"Unknown style {style!r}")
    staged, refused = [], []
    for upload in files:
        name = localfiles.safe_name(upload.filename or "audio")
        if Path(name).suffix.lower() not in localfiles.EXTENSIONS:
            refused.append(name)
            continue
        tmp = settings.work_dir / "imports" / f"upload-{uuid.uuid4().hex[:8]}"
        tmp.mkdir(parents=True)
        with (tmp / name).open("wb") as out:
            shutil.copyfileobj(upload.file, out)
        final = tmp.parent / localfiles.file_id(tmp / name)  # the content decides the song's id
        if final.exists():  # the same file is already waiting (maybe under another name)
            shutil.rmtree(tmp)
            staged.append((Path(name).stem, next(final.iterdir())))
        else:
            tmp.rename(final)
            staged.append((Path(name).stem, final / name))
    if not staged:
        raise HTTPException(400, "None of these files is an audio or video file Rip It Out can read")
    result = manager.submit_files(staged, style, group)
    result["refused"] = refused
    return result


@app.get("/api/jobs")
def jobs() -> list[dict]:
    return manager.snapshot()


@app.post("/api/jobs/{video_id}/retry")
def retry(video_id: str) -> dict:
    if not manager.retry(video_id):
        raise HTTPException(409, "Only failed songs can be retried")
    return {"ok": True}


@app.delete("/api/jobs/{video_id}")
def remove(video_id: str) -> dict:
    if not manager.remove(video_id):
        raise HTTPException(409, "That song is processing right now and can't be removed")
    return {"ok": True}


@app.post("/api/jobs/{video_id}/stop")
def stop(video_id: str) -> dict:
    if not manager.cancel(video_id):
        raise HTTPException(409, "That song isn't waiting or processing")
    return {"ok": True}


@app.post("/api/jobs/clear")
def clear() -> dict:
    return {"removed": manager.clear_finished()}


@app.post("/api/jobs/stop-all")
def stop_all() -> dict:
    return manager.stop_all()


@app.post("/api/shutdown", include_in_schema=False)
async def shutdown(x_shutdown_token: str = Header("")) -> dict:
    """Quits the server the way Ctrl+C does. For the desktop app on Windows, which
    can't send the server a signal; it passes the token in STEMTOOL_SHUTDOWN_TOKEN."""
    token = os.environ.get("STEMTOOL_SHUTDOWN_TOKEN", "")
    if not token or not secrets.compare_digest(x_shutdown_token, token):
        raise HTTPException(404, "Not Found")
    signal.raise_signal(signal.SIGINT)  # uvicorn finishes open requests, then runs the lifespan's end
    return {"ok": True}


@app.get("/api/library")
def songs() -> list[dict]:
    return library.list_songs(settings.library_dir)


@app.get("/api/library/{folder}")
def song(folder: str) -> dict:
    manifest = library.read_manifest(settings.library_dir, folder)
    if manifest is None:
        raise HTTPException(404, "Song not found")
    return manifest


@app.post("/api/library/group")
def set_group(req: GroupRequest) -> dict:
    changed = sum(library.set_group(settings.library_dir, f, req.group) for f in req.folders)
    return {"changed": changed}


@app.post("/api/library/grid")
def regrid(req: GridRequest) -> dict:
    """Clean, reset or edit the beat grid of songs; re-renders their click."""
    if req.action not in pipeline.GRID_ACTIONS:
        raise HTTPException(400, f"Unknown grid action {req.action!r}")
    changed = []
    for folder in req.folders:
        song = _song(folder)
        changed.append(pipeline.regrid(song, req.action, req.steps))
    return {"changed": len(changed), "manifest": changed[0] if len(changed) == 1 else None}


@app.post("/api/library/convert")
def convert_library() -> dict:
    """Queue every song that isn't in four tracks and the chosen format yet (each keeps its style)."""
    queued = sum(manager.reseparate(s["folder"], s["style"], note="converting") for s in _songs_to_convert())
    return {"queued": queued}


@app.post("/api/library/reseparate")
def reseparate(req: ReseparateRequest) -> dict:
    if req.style not in STYLES:
        raise HTTPException(400, f"Unknown style {req.style!r}")
    queued = sum(manager.reseparate(f, req.style) for f in req.folders)
    return {"queued": queued}


# --- takes --------------------------------------------------------------------

@app.get("/api/library/{folder}/takes")
def list_takes(folder: str) -> list[dict]:
    return takes.list_takes(_song(folder))


@app.post("/api/library/{folder}/takes")
def create_take(
    folder: str,
    meta: str = Form(...),
    audio: UploadFile = File(...),
    video: UploadFile | None = File(None),
) -> dict:
    song = _song(folder)
    upload = settings.work_dir / f"upload-{uuid.uuid4().hex[:8]}"
    upload.mkdir(parents=True)
    try:
        raw = upload / "capture.wav"
        with raw.open("wb") as out:
            shutil.copyfileobj(audio.file, out)
        video_path = video_ext = None
        if video is not None and video.filename:
            video_ext = Path(video.filename).suffix.lstrip(".").lower()
            video_path = upload / f"video.{video_ext or 'webm'}"
            with video_path.open("wb") as out:
                shutil.copyfileobj(video.file, out)
        try:
            return takes.create(song, settings.work_dir, json.loads(meta), raw, video_path, video_ext)
        except (takes.TakeError, KeyError, ValueError) as exc:
            raise HTTPException(400, f"Couldn't save the take: {exc}") from exc
    finally:
        shutil.rmtree(upload, ignore_errors=True)


@app.patch("/api/library/{folder}/takes/{take_id}")
def update_take(folder: str, take_id: str, req: TakeUpdate) -> dict:
    try:
        return takes.update(_song(folder), take_id, req.model_dump())
    except takes.TakeError as exc:
        raise HTTPException(404, str(exc)) from exc


@app.post("/api/library/{folder}/takes/{take_id}/export")
def export_take(folder: str, take_id: str, req: ExportRequest) -> dict:
    try:
        return takes.export(_song(folder), take_id, req.gains, req.video, req.start_s, req.end_s)
    except takes.TakeError as exc:
        raise HTTPException(400, str(exc)) from exc


@app.delete("/api/library/{folder}/takes/{take_id}")
def delete_take(folder: str, take_id: str) -> dict:
    if not takes.delete(_song(folder), take_id):
        raise HTTPException(404, "Take not found")
    return {"ok": True}


@app.get("/api/takes")
def all_takes() -> list[dict]:
    return takes.list_all(settings.library_dir)


@app.post("/api/takes/delete")
def delete_takes(req: TakesDeleteRequest) -> dict:
    """Deletes several takes (or only their exports). Unknown songs or take ids are
    skipped and reported, the rest still go."""
    done, missing, freed = 0, [], 0
    for ref in req.takes:
        song = library.song_dir(settings.library_dir, ref.folder)
        path = takes.take_path(song, ref.take_id) if song else None
        if path is None:
            missing.append(ref.model_dump())
            continue
        if req.exports_only:
            freed += takes.delete_exports(song, ref.take_id) or 0
        else:
            freed += takes.sizes(path, {})["total"]
            takes.delete(song, ref.take_id)
        done += 1
    return {"done": done, "missing": missing, "freed_bytes": freed}
