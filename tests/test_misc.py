import numpy as np
import pytest

from stemtool import click, separation, youtube


@pytest.mark.parametrize("url, ok", [
    ("https://www.youtube.com/watch?v=x", True),
    ("https://youtu.be/x", True),
    ("https://music.youtube.com/playlist?list=x", True),
    ("http://m.youtube.com/watch?v=x", True),
    ("https://vimeo.com/1", False),
    ("https://youtube.com.evil.example/watch?v=1", False),
    ("https://evil.example/?u=youtube.com", False),
    ("ftp://youtube.com/x", False),
    ("not a url", False),
])
def test_only_youtube_links(url, ok):
    assert youtube.is_youtube_url(url) is ok


def test_expand_refuses_other_sites():
    with pytest.raises(ValueError):
        youtube.expand("https://vimeo.com/1")


def test_click_has_the_song_length():
    audio = click.render_audio([0.5, 1.0, 1.5], [0.5], 44100 * 3, 44100)
    assert audio.shape == (44100 * 3, 2)
    assert np.abs(audio[int(0.5 * 44100):int(0.55 * 44100)]).max() > 0.1


def test_electronic_refinement_keeps_the_sum():
    rng = np.random.default_rng(1)
    sr = 44100
    t = np.arange(sr * 4) / sr
    bass = 0.4 * np.sin(2 * np.pi * 55 * t)
    kicks = np.zeros_like(t)
    for start in np.arange(0, 4, 0.5):
        i = int(start * sr)
        kicks[i:i + 4000] += np.sin(2 * np.pi * 60 * t[:4000]) * np.exp(-t[:4000] * 30)
    drums = np.stack([bass + kicks] * 2, axis=1).astype(np.float32)  # Demucs put the bass in the drums
    other = (rng.standard_normal(drums.shape) * 0.01).astype(np.float32)
    kept, moved = separation.refine_electronic(drums, other, sr)
    assert np.allclose(kept + moved, drums + other, atol=1e-5)
    assert separation.drum_share(kept, moved) < separation.drum_share(drums, other)


def test_license_check_flags_gpl_but_not_lgpl():
    import importlib.util
    import pathlib

    path = pathlib.Path(__file__).parents[1] / "macos" / "license_report.py"
    spec = importlib.util.spec_from_file_location("license_report", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    assert mod.is_gpl("GPL-2.0-or-later")
    assert mod.is_gpl("GNU General Public License v2 or later (GPLv2+)")
    assert mod.is_gpl("AGPL-3.0")
    assert not mod.is_gpl("LGPL-2.1-or-later")
    assert not mod.is_gpl("GNU Lesser General Public License v3 (LGPLv3)")
    assert not mod.is_gpl("MIT")


@pytest.mark.parametrize("fmt", ["aac256", "flac16", "flac24"])
def test_stem_formats_keep_length_and_alignment(tmp_path, fmt):
    import shutil

    from stemtool import audio

    if fmt == "aac256" and not shutil.which("ffmpeg"):
        pytest.skip("ffmpeg not installed")
    rng = np.random.default_rng(0)
    x = (rng.standard_normal((44100 * 5, 2)) * 0.1).astype(np.float32)
    x[44100 * 2] = 0.9  # a click at exactly 2 s
    name = audio.write_stem(tmp_path, "drums", x, 44100, fmt)
    y, sr = audio.read(tmp_path / name)
    assert sr == 44100 and len(y) == len(x)
    assert abs(int(np.argmax(np.abs(y[:, 0]))) - 44100 * 2) <= 1
    assert np.allclose(audio.read_range(tmp_path / name, 44100, 100), y[44100:44100 + 100])
