"""A simple in-memory job queue with one worker thread (the GPU is the bottleneck,
so songs are processed one at a time). Each song runs in a child process so it
can be stopped.

Job state is not persisted: the library on disk is the record of what's done.
After a restart, submit the playlist again and only the missing songs are queued.
"""

from __future__ import annotations

import logging
import multiprocessing as mp
import queue
import shutil
import threading
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

from . import library, pipeline, youtube
from .config import Settings

log = logging.getLogger("stemtool")

QUEUED, RUNNING, DONE, FAILED = "queued", "running", "done", "failed"


@dataclass
class Job:
    video_id: str
    title: str
    url: str
    style: str = "standard"
    group: str = ""
    reseparate: str = ""  # folder name: redo the separation of a library song instead of downloading
    source_file: str = ""  # an imported audio file (in the work folder) instead of a YouTube video
    status: str = QUEUED
    stage: str = ""
    error: str = ""
    folder: str = ""
    added_at: float = field(default_factory=time.time)
    started_at: float | None = None
    finished_at: float | None = None


class JobManager:
    def __init__(self, settings: Settings):
        self.settings = settings
        self._jobs: dict[str, Job] = {}
        self._lock = threading.Lock()
        self._queue: queue.Queue[str] = queue.Queue()
        self._thread: threading.Thread | None = None
        self._proc: mp.process.BaseProcess | None = None
        self._guard = None  # the running child's stop guard, see stop_process
        self._stopping = False

    def start(self) -> None:
        if self._thread is None:
            self._thread = threading.Thread(target=self._worker, name="stemtool-worker", daemon=True)
            self._thread.start()

    # --- public API -------------------------------------------------------

    def submit(self, url: str, style: str = "standard", group: str | None = None) -> dict:
        playlist_title, refs = youtube.expand(url)
        group = playlist_title if group is None else group.strip()
        in_library = library.known_video_ids(self.settings.library_dir)
        added = already = pending = 0
        with self._lock:
            for ref in refs:
                if ref.video_id in in_library:
                    already += 1
                    continue
                existing = self._jobs.get(ref.video_id)
                if existing and existing.status in (QUEUED, RUNNING):
                    pending += 1
                    continue
                self._jobs[ref.video_id] = Job(ref.video_id, ref.title, ref.url, style, group)  # new, or retry of failed
                self._queue.put(ref.video_id)
                added += 1
        return {"found": len(refs), "added": added, "already_in_library": already, "already_queued": pending,
                "group": group}

    def submit_files(self, files: list[tuple[str, Path]], style: str = "standard", group: str = "") -> dict:
        """Queue imported audio files: [(original name, path in the work folder)]."""
        in_library = library.known_video_ids(self.settings.library_dir)
        added = already = pending = 0
        with self._lock:
            for name, path in files:
                file_id = path.parent.name
                existing = self._jobs.get(file_id)
                if file_id in in_library or (existing and existing.status in (QUEUED, RUNNING)):
                    if file_id in in_library:
                        already += 1
                    else:
                        pending += 1
                    if not (existing and existing.status in (QUEUED, RUNNING)):
                        shutil.rmtree(path.parent, ignore_errors=True)
                    continue
                self._jobs[file_id] = Job(file_id, name, "", style, group.strip(), source_file=str(path))
                self._queue.put(file_id)
                added += 1
        return {"found": len(files), "added": added, "already_in_library": already, "already_queued": pending,
                "group": group.strip()}

    def reseparate(self, folder: str, style: str, note: str | None = None) -> bool:
        manifest = library.read_manifest(self.settings.library_dir, folder)
        if manifest is None:
            return False
        video_id = manifest.get("video_id") or folder
        with self._lock:
            existing = self._jobs.get(video_id)
            if existing and existing.status in (QUEUED, RUNNING):
                return False
            title = f"{manifest.get('title') or folder} ({note or f'redo as {style}'})"
            self._jobs[video_id] = Job(video_id, title, manifest.get("source_url", ""), style,
                                       reseparate=folder)
            self._queue.put(video_id)
            return True

    def retry(self, video_id: str) -> bool:
        with self._lock:
            job = self._jobs.get(video_id)
            if not job or job.status != FAILED:
                return False
            self._jobs[video_id] = Job(job.video_id, job.title, job.url, job.style, job.group, job.reseparate,
                                       source_file=job.source_file)
            self._queue.put(video_id)
            return True

    def remove(self, video_id: str) -> bool:
        with self._lock:
            job = self._jobs.get(video_id)
            if not job or job.status == RUNNING:
                return False
            del self._jobs[video_id]  # a queued id left in the queue is skipped by the worker
            _drop_import(job.source_file)
            return True

    def clear_finished(self) -> int:
        with self._lock:
            finished = [k for k, j in self._jobs.items() if j.status in (DONE, FAILED)]
            for k in finished:
                _drop_import(self._jobs.pop(k).source_file)
            return len(finished)

    def snapshot(self) -> list[dict]:
        with self._lock:
            return [asdict(j) for j in self._jobs.values()]

    def cancel(self, video_id: str) -> bool:
        """Stop a running job (its process is terminated) or drop a queued one."""
        with self._lock:
            job = self._jobs.get(video_id)
            if not job or job.status not in (QUEUED, RUNNING):
                return False
            if job.status == QUEUED:
                del self._jobs[video_id]
                _drop_import(job.source_file)
                return True
            job.stage = "Stopping"
            proc, guard = self._proc, self._guard
            self._stopping = True
        if proc is not None:
            stop_process(proc, guard)
        return True

    def busy(self) -> bool:
        with self._lock:
            return any(j.status in (QUEUED, RUNNING) for j in self._jobs.values())

    def stop_all(self) -> dict:
        """Drop every waiting job and stop the running one."""
        with self._lock:
            waiting = [k for k, j in self._jobs.items() if j.status == QUEUED]
            for k in waiting:
                _drop_import(self._jobs.pop(k).source_file)
            running = next((k for k, j in self._jobs.items() if j.status == RUNNING), None)
        if running:
            self.cancel(running)
        return {"removed": len(waiting), "stopped": 1 if running else 0}

    # --- worker -------------------------------------------------------------

    def _update(self, video_id: str, **changes) -> Job | None:
        with self._lock:
            job = self._jobs.get(video_id)
            if job:
                for key, value in changes.items():
                    setattr(job, key, value)
            return job

    def _worker(self) -> None:
        while True:
            video_id = self._queue.get()
            with self._lock:
                job = self._jobs.get(video_id)
                if not job or job.status != QUEUED:
                    continue  # removed, or a stale duplicate queue entry
                job.status, job.started_at, job.stage = RUNNING, time.time(), "Starting"
                ref = youtube.VideoRef(job.video_id, job.title, job.url, job.source_file)
                style, group, reseparate = job.style, job.group, job.reseparate

            if not reseparate and video_id in library.known_video_ids(self.settings.library_dir):
                self._update(video_id, status=DONE, stage="Already in library", finished_at=time.time())
                continue

            log.info("Processing %s (%s, %s)", ref.title, ref.video_id, style)
            try:
                folder = self._run_in_child(video_id, ref, style, group, reseparate)
            except _Cancelled:
                log.info("Stopped: %s", ref.url or ref.title)
                with self._lock:
                    self._jobs.pop(video_id, None)
                _drop_import(ref.file)
            except Exception as exc:  # noqa: BLE001 (one bad video must not stop the queue)
                log.error("Failed: %s: %s", ref.url, exc)
                self._update(video_id, status=FAILED, error=str(exc)[:500] or type(exc).__name__,
                             finished_at=time.time())
            else:
                self._update(video_id, status=DONE, stage="Done", folder=folder, finished_at=time.time())
                _drop_import(ref.file)  # a failed import keeps its file, so Retry works

    def _run_in_child(self, video_id: str, ref: youtube.VideoRef, style: str, group: str, reseparate: str) -> str:
        """Runs the pipeline in its own process, so Stop can end it at any point
        (a thread can't be interrupted in the middle of Demucs). Models load once
        per song this way, which costs a few seconds against minutes of work."""
        ctx = mp.get_context("spawn")
        messages, guard = ctx.Queue(), ctx.Lock()
        proc = ctx.Process(target=_child, args=(messages, guard, self.settings, ref, style, group, reseparate),
                           name=f"stemtool-{video_id}", daemon=True)
        with self._lock:
            self._proc, self._guard, self._stopping = proc, guard, False
        proc.start()
        try:
            while True:
                try:
                    kind, value = messages.get(timeout=0.5)
                except queue.Empty:
                    if proc.is_alive():
                        continue
                    try:  # the last message may arrive just after the process exits
                        kind, value = messages.get(timeout=1)
                    except queue.Empty:
                        with self._lock:
                            stopped = self._stopping
                        if stopped:
                            raise _Cancelled() from None
                        raise RuntimeError(f"Processing stopped unexpectedly (exit code {proc.exitcode})") from None
                if kind == "stage":
                    self._update(video_id, stage=value)
                elif kind == "done":
                    return value
                elif kind == "error":
                    raise RuntimeError(value)
        finally:
            proc.join(timeout=30)
            with self._lock:
                self._proc = self._guard = None
            # a stopped job leaves its work folder behind
            work = f"reseparate-{reseparate}" if reseparate else ref.video_id
            shutil.rmtree(self.settings.work_dir / work, ignore_errors=True)


class _Cancelled(Exception):
    pass


def stop_process(proc: mp.process.BaseProcess, guard, timeout: float = 120) -> None:
    """Ends a child process, but never while it holds its guard (a block that must
    not be cut short, see pipeline._no_stop). On Windows terminate() is a hard kill
    that no signal handler can defer, so waiting for the lock is what keeps files whole."""
    got = guard.acquire(timeout=timeout)
    try:
        if proc.is_alive():
            proc.terminate()
            proc.join(timeout=10)
    finally:
        if got:
            guard.release()


def _drop_import(source_file: str) -> None:
    """Delete an imported file (its own folder in the work folder) once it's not needed."""
    if source_file:
        shutil.rmtree(Path(source_file).parent, ignore_errors=True)


def _child(messages, guard, settings: Settings, ref: youtube.VideoRef, style: str, group: str,
           reseparate: str) -> None:
    pipeline.stop_guard = guard
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    on_stage = lambda s: messages.put(("stage", s))  # noqa: E731
    try:
        if reseparate:
            folder = pipeline.reseparate(reseparate, settings, on_stage, style)
        else:
            folder = pipeline.process(ref, settings, on_stage, style, group)
    except Exception as exc:  # noqa: BLE001
        log.exception("Failed: %s", ref.url)
        messages.put(("error", str(exc)[:500] or type(exc).__name__))
    else:
        messages.put(("done", folder.name))
