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
