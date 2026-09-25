"""The API, against a temporary library."""


def test_status_and_library(client):
    status = client.get("/api/status").json()
    assert status["library_locked"] is False
    songs = client.get("/api/library").json()
    assert [s["title"] for s in songs] == ["Test Song"]


def test_submit_refuses_other_sites(client):
    r = client.post("/api/submit", json={"url": "https://vimeo.com/123"})
    assert r.status_code == 400


def test_files_stay_inside_the_library(client):
    assert client.get("/files/test-song__abc123/manifest.json").status_code == 200
    assert client.get("/files/../settings.json").status_code == 404
    assert client.get("/files/test-song__abc123/%2e%2e/%2e%2e/settings.json").status_code == 404
    assert client.get("/files/.stemtool-work/x").status_code == 404


def test_switch_library(client, tmp_path):
    other = tmp_path / "other"
    r = client.put("/api/settings", json={"library_dir": str(other)})
    assert r.status_code == 200 and r.json()["library_dir"] == str(other.resolve())
    assert client.get("/api/library").json() == []
    assert client.put("/api/settings", json={"library_dir": "relative/path"}).status_code == 400


def test_grid_edit_rewrites_beats_and_click(client, song):
    before = client.get("/api/library/test-song__abc123").json()
    r = client.post("/api/library/grid", json={"folders": ["test-song__abc123"], "action": "shift", "steps": 1})
    assert r.status_code == 200
    after = r.json()["manifest"]
    assert after["downbeats"][0] == before["beats"][1]
    assert after["beats_raw"] == before["beats"]
    assert (song / "click.mid").stat().st_size > 0
    reset = client.post("/api/library/grid", json={"folders": ["test-song__abc123"], "action": "reset"}).json()
    assert reset["manifest"]["downbeats"] == before["downbeats"]


def test_format_setting_and_conversion(client):
    status = client.get("/api/status").json()
    assert status["stem_format"] == "aac256" and "flac16" in status["formats"]
    assert status["to_convert"] == 1  # the test song is stored as 24-bit FLAC
    r = client.put("/api/settings", json={"stem_format": "flac24"})
    assert r.status_code == 200 and r.json()["to_convert"] == 0
    assert client.put("/api/settings", json={"stem_format": "mp3"}).status_code == 400


def test_import_files_dedups_by_content(client, monkeypatch, tmp_path):
    import io

    import numpy as np
    import soundfile as sf

    import stemtool.server as server

    monkeypatch.setattr(server.manager._queue, "put", lambda _id: None)  # queue only, don't process
    buf = io.BytesIO()
    sf.write(buf, np.zeros((44100, 2), np.float32), 44100, format="WAV")
    wav = buf.getvalue()
    files = [("files", ("Band - Song.wav", wav, "audio/wav")),
             ("files", ("copy of it.wav", wav, "audio/wav")),
             ("files", ("notes.txt", b"hello", "text/plain"))]
    r = client.post("/api/import", files=files, data={"style": "standard", "group": "Mine"}).json()
    assert r["added"] == 1 and r["already_queued"] == 1 and r["refused"] == ["notes.txt"]
    jobs = client.get("/api/jobs").json()
    assert len(jobs) == 1 and jobs[0]["video_id"].startswith("file-") and jobs[0]["group"] == "Mine"
    staged = server.Path(jobs[0]["source_file"])
    assert staged.is_file()
    client.delete(f"/api/jobs/{jobs[0]['video_id']}")
    assert not staged.parent.exists()  # removing the job removes the uploaded file


def test_file_titles_from_tags_or_name(tmp_path):
    import shutil

    import numpy as np
    import pytest
    import soundfile as sf

    from stemtool import localfiles

    if not shutil.which("ffprobe"):
        pytest.skip("ffprobe not installed")
    path = tmp_path / "x.wav"
    sf.write(str(path), np.zeros((4410, 2), np.float32), 44100)
    meta = localfiles.read_meta(path, "The Band - Great Song.wav")
    assert meta["title"] == "Great Song" and meta["artist"] == "The Band"
    assert localfiles.read_meta(path, "just a title.wav")["title"] == "just a title"
