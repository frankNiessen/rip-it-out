import json
import shutil
from pathlib import Path

import pytest

from stemtool import demo, library

from .conftest import make_song


@pytest.fixture
def config_file(tmp_path: Path, monkeypatch) -> Path:
    path = tmp_path / "settings.json"
    monkeypatch.setenv("STEMTOOL_CONFIG", str(path))
    return path


@pytest.fixture
def fake_demo(tmp_path: Path, monkeypatch) -> Path:
    shipped = tmp_path / "shipped"
    make_song(shipped, "demo-song__demo-x", "demo-x")
    monkeypatch.setattr(demo, "DEMO_DIR", shipped)
    return shipped


def test_added_to_an_empty_library_once(library, config_file, fake_demo):
    assert demo.add_to(library)
    assert library.joinpath("demo-song__demo-x", "manifest.json").is_file()
    assert not list((library / ".stemtool-work").iterdir())

    shutil.rmtree(library / "demo-song__demo-x")
    assert not demo.add_to(library)  # a deleted demo stays deleted
    assert not list(library.glob("demo-*"))


def test_not_added_to_a_library_with_songs(library, song, config_file, fake_demo):
    assert not demo.add_to(library)
    assert not (library / "demo-song__demo-x").exists()
    assert json.loads(config_file.read_text())[demo.CONFIG_KEY] is True  # and not later either


def test_shipped_demo_is_a_complete_song():
    songs = list(demo.DEMO_DIR.glob(f"*/{library.MANIFEST}"))
    assert len(songs) == 1
    folder = songs[0].parent
    m = json.loads(songs[0].read_text(encoding="utf-8"))
    assert m["schema"] == library.SCHEMA_VERSION
    assert m["license"]["url"].startswith("https://creativecommons.org/")
    assert m["beats"] and m["downbeats"] and m["sections"]
    files = [*m["stems"].values(), m["click"]["audio"], m["click"]["midi"]]
    assert sorted(m["stems"]) == ["bass", "drums", "other", "vocals"]
    assert all((folder / f).is_file() for f in files)
    assert sorted(p.name for p in folder.iterdir()) == sorted([*files, library.MANIFEST])
