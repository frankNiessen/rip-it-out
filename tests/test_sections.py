"""Sections: turning the model's segments into what the app shows, and the model's
input and post-processing."""

import numpy as np
import pytest

from stemtool import sections
from stemtool.structure import postprocess, spectrogram

DOWNBEATS = list(np.arange(0.2, 120, 2.0))  # a bar every 2 s


def test_merges_snaps_and_numbers():
    segs = [
        {"start": 0.0, "end": 0.4, "label": "start"},
        {"start": 0.4, "end": 16.3, "label": "intro"},
        {"start": 16.3, "end": 31.9, "label": "verse"},
        {"start": 31.9, "end": 48.1, "label": "verse"},  # the model split a verse
        {"start": 48.1, "end": 64.0, "label": "chorus"},
        {"start": 64.0, "end": 96.2, "label": "verse"},
        {"start": 96.2, "end": 112.0, "label": "chorus"},
        {"start": 112.0, "end": 120.0, "label": "end"},
    ]
    found = sections.from_segments(segs, DOWNBEATS, 120.0)
    assert [s["label"] for s in found] == ["Intro", "Verse 1", "Chorus 1", "Verse 2", "Chorus 2"]
    assert found[0]["start"] == 0.0 and found[-1]["end"] == 120.0
    assert found[1]["start"] == 16.2 and found[1]["bar"] == 9  # snapped to the bar line
    assert all(a["end"] == b["start"] for a, b in zip(found, found[1:]))


def test_tiny_piece_joins_its_neighbour():
    segs = [{"start": 0, "end": 30, "label": "verse"}, {"start": 30, "end": 31, "label": "inst"},
            {"start": 31, "end": 60, "label": "chorus"}]
    found = sections.from_segments(segs, DOWNBEATS, 60.0)
    assert [s["kind"] for s in found] == ["verse", "chorus"]


def test_snap_moves_borders_to_new_bar_lines():
    secs = [{"start": 0.0, "end": 16.0, "label": "A"}, {"start": 16.0, "end": 32.0, "label": "B"}]
    moved = sections.snap(secs, list(np.arange(0.5, 32, 2.0)), 32.0)
    assert moved[1]["start"] == 16.5 and moved[0]["end"] == 16.5


def test_filterbank_matches_the_model_input():
    fb = spectrogram.filterbank()
    assert fb.shape == (1024, 81)  # 81 bands, as the model expects
    assert np.allclose(fb.sum(axis=0), 1, atol=1e-5)
    spec = spectrogram.spectrogram(np.zeros(44100, np.float32))
    assert spec.shape == (100, 81) and spec.max() == 0


def test_spectrogram_matches_madmom():
    madmom = pytest.importorskip("madmom")  # only where madmom happens to be installed
    from madmom.audio.filters import LogarithmicFilterbank
    from madmom.audio.stft import fft_frequencies

    ref = np.asarray(LogarithmicFilterbank(fft_frequencies(1024, 44100), num_bands=12, fmin=30, fmax=17000,
                                           norm_filters=True))
    assert np.abs(ref - spectrogram.filterbank()).max() < 1e-6


def test_boundaries_are_the_clear_peaks():
    prob = 0.02 + np.random.default_rng(1).random(6000) * 0.01  # the model is never perfectly flat
    for frame in (1500, 3000, 4500):  # sections every 15 s
        prob[frame - 20:frame + 20] += np.hanning(40) * 0.9
    found = postprocess.boundaries(prob)
    assert [abs(f - t) < 3 for f, t in zip(found, (1500, 3000, 4500))] == [True] * 3 and len(found) == 3


def test_model_runs_when_available():
    pytest.importorskip("torch")
    from stemtool import structure

    if not all((structure.cache_dir() / w).is_file() for w in structure.WEIGHTS):
        pytest.skip("section model weights not downloaded")
    rng = np.random.default_rng(0)
    stems = {k: rng.standard_normal((44100 * 20, 2)).astype(np.float32) * 0.05 for k in structure.INSTRUMENTS}
    segs = structure.segments(stems, 44100)
    assert segs and segs[0]["start"] == 0 and abs(segs[-1]["end"] - 20) < 0.1
