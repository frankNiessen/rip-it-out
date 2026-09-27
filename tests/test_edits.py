"""Editing a song's sections and normalizing a take."""

import numpy as np
import pytest
import soundfile as sf

from stemtool import sections, takes

from .conftest import SR

DOWNBEATS = [0.5 + 2.0 * i for i in range(30)]


def test_edited_sections_snap_sort_and_number():
    found = sections.edited([{"start": 20.3, "kind": "chorus"}, {"start": 0.4, "kind": "verse"},
                             {"start": 40.1, "kind": "verse"}], DOWNBEATS, 60.0)
    assert [s["label"] for s in found] == ["Verse 1", "Chorus", "Verse 2"]
    assert [s["start"] for s in found] == [0.0, 20.5, 40.5]  # the first starts at 0, the rest on bar lines
    assert [s["end"] for s in found] == [20.5, 40.5, 60.0]


def test_edited_sections_same_bar_keeps_the_later_one():
    found = sections.edited([{"start": 0, "kind": "intro"}, {"start": 10.4, "kind": "verse"},
                             {"start": 10.6, "kind": "solo"}], DOWNBEATS, 30.0)
    assert [s["kind"] for s in found] == ["intro", "solo"]


def test_edited_sections_reject_unknown_kind():
    with pytest.raises(ValueError):
        sections.edited([{"start": 0, "kind": "kazoo"}], DOWNBEATS, 30.0)


def test_sections_endpoint_edit_and_reset(client, song):
    folder = song.name
    detected = client.get(f"/api/library/{folder}").json().get("sections")
    r = client.put(f"/api/library/{folder}/sections", json={"sections": [
        {"start": 0, "kind": "intro"}, {"start": 4.4, "kind": "chorus"}]})
    assert r.status_code == 200
    assert [s["label"] for s in r.json()["sections"]] == ["Intro", "Chorus"]
    assert client.put(f"/api/library/{folder}/sections", json={"sections": [{"start": 0, "kind": "x"}]}).status_code == 400
    back = client.put(f"/api/library/{folder}/sections", json={"sections": None}).json()
    assert back.get("sections") == (detected or []) and "sections_detected" not in back


def quiet_take(tmp_path, song, level):
    raw = np.zeros((SR * 2, 2), np.float32)
    raw[SR // 2: SR] = level
    path = tmp_path / "capture.wav"
    sf.write(str(path), raw, SR, subtype="FLOAT")
    return takes.create(song, tmp_path / "work", {"capture_start_s": 1.0, "latency_ms": 0}, path, None, None)


def test_normalize_take_and_back(tmp_path, song):
    take = quiet_take(tmp_path, song, 0.1)  # -20 dBFS
    mine = song / "takes" / take["id"] / "my_drums.flac"
    before = np.abs(sf.read(str(mine))[0]).max()
    t = takes.update(song, take["id"], {"normalize": True})
    assert t["gain_db"] == pytest.approx(19.0, abs=0.1)
    assert np.abs(sf.read(str(mine))[0]).max() == pytest.approx(10 ** (-1 / 20), abs=0.01)
    t = takes.update(song, take["id"], {"normalize": False})
    assert t["gain_db"] == 0 and np.abs(sf.read(str(mine))[0]).max() == pytest.approx(before, abs=1e-3)
