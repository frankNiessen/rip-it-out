"""Stopping work portably: the queue's stop guard and the desktop app's shutdown call.
Both must behave the same on Windows, where ending a process is a hard kill."""

from __future__ import annotations

import json
import multiprocessing as mp
import os
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import pytest

from stemtool import config, localfiles
from stemtool.jobs import stop_process


def _guarded_write(guard, entered, path: str) -> None:
    """Holds the guard while writing a file slowly, like pipeline._no_stop."""
    with guard:
        entered.set()
        with open(path, "w", encoding="utf-8") as f:
            for i in range(5):
                f.write(f"{i}\n")
                f.flush()
                time.sleep(0.2)
            f.write("end\n")
    time.sleep(60)


def _idle(entered) -> None:
    entered.set()
    time.sleep(60)


def test_stop_waits_for_the_guarded_block(tmp_path: Path):
    ctx = mp.get_context("spawn")
    guard, entered = ctx.Lock(), ctx.Event()
    target = tmp_path / "out.txt"
    proc = ctx.Process(target=_guarded_write, args=(guard, entered, str(target)), daemon=True)
    proc.start()
    assert entered.wait(30)
    stop_process(proc, guard)
    assert not proc.is_alive()
    assert target.read_text(encoding="utf-8").endswith("end\n")


def test_stop_ends_an_unguarded_process_at_once():
    ctx = mp.get_context("spawn")
    guard, entered = ctx.Lock(), ctx.Event()
    proc = ctx.Process(target=_idle, args=(entered,), daemon=True)
    proc.start()
    assert entered.wait(30)
    started = time.monotonic()
    stop_process(proc, guard)
    assert not proc.is_alive()
    assert time.monotonic() - started < 10


def test_shutdown_needs_the_token(client, monkeypatch):
    assert client.post("/api/shutdown").status_code == 404  # no token set: not available
    monkeypatch.setenv("STEMTOOL_SHUTDOWN_TOKEN", "secret")
    assert client.post("/api/shutdown", headers={"X-Shutdown-Token": "wrong"}).status_code == 404


def test_shutdown_ends_the_server(tmp_path: Path, library: Path):
    """A real uvicorn process quits cleanly when asked, as the desktop app does on Windows."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    settings = tmp_path / "settings.json"
    settings.write_text(json.dumps({"library": str(library)}), encoding="utf-8")
    env = {**os.environ, "STEMTOOL_CONFIG": str(settings), "STEMTOOL_SHUTDOWN_TOKEN": "secret"}
    env.pop("STEMTOOL_LIBRARY", None)
    proc = subprocess.Popen([sys.executable, "-m", "uvicorn", "stemtool.server:app", "--port", str(port)],
                            env=env, cwd=Path(__file__).parent.parent,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        base = f"http://127.0.0.1:{port}"
        for _ in range(150):
            try:
                urllib.request.urlopen(f"{base}/api/status", timeout=1)
                break
            except OSError:
                time.sleep(0.2)
        else:
            pytest.fail("The server didn't start")
        req = urllib.request.Request(f"{base}/api/shutdown", method="POST", headers={"X-Shutdown-Token": "secret"})
        urllib.request.urlopen(req, timeout=5)
        assert proc.wait(timeout=30) == 0
    finally:
        if proc.poll() is None:
            proc.kill()


def test_config_file_per_platform(monkeypatch, tmp_path: Path):
    monkeypatch.delenv("STEMTOOL_CONFIG", raising=False)
    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.setenv("APPDATA", str(tmp_path))
    assert config.config_file() == tmp_path / "Rip It Out" / "settings.json"
    monkeypatch.setattr(sys, "platform", "darwin")
    assert config.config_file().parts[-4:] == ("Library", "Application Support", "Rip It Out", "settings.json")


def test_imported_names_stay_short():
    name = localfiles.safe_name("x" * 300 + ".flac")
    assert name.endswith(".flac") and len(name) <= 110
    assert localfiles.safe_name("music/Song: live?.mp3") == "Song_ live_.mp3"
