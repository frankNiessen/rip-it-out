"""The library-wide take overview: listing with disk use, bulk delete, bad ids."""

import json

from .conftest import make_song


def fake_take(song, take_id, video=False, export=False):
    """A take folder with files of known sizes (contents don't matter here)."""
    path = song / "takes" / take_id
    path.mkdir(parents=True)
    (path / "my_drums.flac").write_bytes(b"a" * 1000)
    (path / "raw.flac").write_bytes(b"r" * 500)
    take = {"schema": 1, "id": take_id, "created_at": f"2026-09-{take_id[-2:]}T10:00:00+00:00", "name": "",
            "start_s": 1.0, "captured_s": 4.0, "video": None}
    if video:
        (path / "video.webm").write_bytes(b"v" * 3000)
        take["video"] = {"file": "video.webm", "start_s": 1.0}
    if export:
        (path / "export.wav").write_bytes(b"e" * 200)
        (path / "export.mp4").write_bytes(b"m" * 300)
    (path / "take.json").write_text(json.dumps(take))
    return path


def test_lists_takes_of_all_songs_with_sizes(client, library, song):
    other = make_song(library, "other-song__xyz789", "xyz789")
    fake_take(song, "2026-09-01", video=True, export=True)
    fake_take(other, "2026-09-02")
    listed = client.get("/api/takes").json()
    assert [(t["folder"], t["id"]) for t in listed] == [
        ("other-song__xyz789", "2026-09-02"), ("test-song__abc123", "2026-09-01")]
    big = listed[1]
    assert big["title"] == "Test Song" and big["has_video"] and big["has_export"]
    assert big["bytes"]["audio"] == 1500 and big["bytes"]["video"] == 3000 and big["bytes"]["exports"] == 500
    assert big["bytes"]["total"] >= 5000  # plus take.json
    assert listed[0]["bytes"]["video"] == 0 and not listed[0]["has_video"]


def test_bulk_delete(client, library, song):
    other = make_song(library, "other-song__xyz789", "xyz789")
    fake_take(song, "2026-09-01", video=True)
    fake_take(song, "2026-09-03")
    fake_take(other, "2026-09-02")
    r = client.post("/api/takes/delete", json={"takes": [
        {"folder": "test-song__abc123", "take_id": "2026-09-01"},
        {"folder": "other-song__xyz789", "take_id": "2026-09-02"},
    ]}).json()
    assert r["done"] == 2 and r["missing"] == [] and r["freed_bytes"] >= 6000
    assert [t["id"] for t in client.get("/api/takes").json()] == ["2026-09-03"]
    counts = {s["folder"]: s["takes"] for s in client.get("/api/library").json()}
    assert counts == {"test-song__abc123": 1, "other-song__xyz789": 0}


def test_delete_only_exports(client, song):
    path = fake_take(song, "2026-09-01", video=True, export=True)
    r = client.post("/api/takes/delete", json={"exports_only": True, "takes": [
        {"folder": "test-song__abc123", "take_id": "2026-09-01"}]}).json()
    assert r == {"done": 1, "missing": [], "freed_bytes": 500}
    assert not list(path.glob("export.*")) and (path / "video.webm").is_file() and (path / "take.json").is_file()


def test_bulk_delete_rejects_bad_ids_and_paths(client, library, song, tmp_path):
    fake_take(song, "2026-09-01")
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "take.json").write_text("{}")
    bad = [
        {"folder": "test-song__abc123", "take_id": "../../outside"},
        {"folder": "test-song__abc123", "take_id": ".."},
        {"folder": "test-song__abc123", "take_id": "nope"},
        {"folder": "../outside", "take_id": "x"},
        {"folder": ".stemtool-work", "take_id": "x"},
        {"folder": "missing-song", "take_id": "2026-09-01"},
    ]
    r = client.post("/api/takes/delete", json={"takes": bad}).json()
    assert r["done"] == 0 and len(r["missing"]) == len(bad) and r["freed_bytes"] == 0
    assert (outside / "take.json").is_file() and (song / "takes" / "2026-09-01").is_dir()
    assert client.post("/api/takes/delete", json={"takes": [{"folder": "x"}]}).status_code == 422
