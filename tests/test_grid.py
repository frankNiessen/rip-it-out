"""The beat grid cleanup: it must remove tracker jumps but keep the real timing."""

import numpy as np

from stemtool import grid


def steady(bpm=174.0, seconds=60.0, start=0.3):
    period = 60 / bpm
    return np.arange(start, seconds, period)


def bars(beats, bpb=4, phase=0):
    return list(beats[phase::bpb])


def assert_close_to(result, truth, tol=0.012):
    result, truth = np.asarray(result), np.asarray(truth)
    idx = np.clip(np.searchsorted(result, truth), 1, len(result) - 1)
    nearest = np.minimum(abs(result[idx - 1] - truth), abs(result[idx] - truth))
    assert np.max(nearest) < tol
    assert abs(len(result) - len(truth)) <= 1


def test_clean_keeps_a_clean_grid():
    truth = steady()
    b, db, bpb = grid.clean(list(truth), bars(truth))
    assert bpb == 4
    assert_close_to(b, truth, tol=0.002)
    assert grid.uneven_fraction(b, db) == 0


def test_missing_beats_are_filled_and_extra_beats_dropped():
    truth = steady()
    tracked = np.delete(truth, [20, 21, 80, 150])  # the tracker lost some beats
    offbeats = truth[100:140] + (truth[1] - truth[0]) / 2  # and briefly went to double time
    tracked = np.sort(np.concatenate([tracked, offbeats]))
    b, db, _ = grid.clean(list(tracked), bars(truth))
    assert_close_to(b, truth)
    assert grid.uneven_fraction(b, db) == 0


def test_half_time_stretch_is_brought_back_to_the_song_tempo():
    truth = steady()
    tracked = np.concatenate([truth[:80], truth[80:160:2], truth[160:]])  # 88 bpm for a while
    b, db, _ = grid.clean(list(tracked), bars(truth))
    assert_close_to(b, truth)


def test_dotted_hits_do_not_drag_the_tempo():
    truth = steady()
    period = truth[1] - truth[0]
    tracked = list(truth[:60])
    t = truth[60]
    while t < truth[120]:  # the tracker followed a dotted rhythm: 1.5 + 0.5 beats
        tracked += [t, t + 1.5 * period]
        t += 2 * period
    tracked += list(truth[120:])
    b, _, _ = grid.clean(tracked, bars(truth))
    assert_close_to(b, truth, tol=0.03)


def test_real_tempo_change_is_followed():
    intro = np.arange(0.3, 20, 60 / 130)  # an intro at 130 bpm, then 100 bpm
    main = np.arange(intro[-1] + 60 / 100, 60, 60 / 100)
    truth = np.concatenate([intro, main])
    b, _, _ = grid.clean(list(truth), bars(truth))
    assert_close_to(b, truth, tol=0.01)


def test_short_bar_line_blip_is_ignored():
    truth = steady()
    raw_db = bars(truth)
    raw_db[10:13] = [x + (truth[1] - truth[0]) for x in raw_db[10:13]]  # 3 bars with the "1" one beat late
    b, db, _ = grid.clean(list(truth), raw_db)
    assert grid.uneven_fraction(b, db) == 0
    assert_close_to(db, bars(truth), tol=0.002)


def test_manual_edits():
    truth = steady(bpm=120)
    b, db = list(truth), bars(truth)
    shifted = grid.shift_downbeats(b, db, 1, 4)
    assert abs(shifted[0] - truth[1]) < 1e-3
    doubled, ddb = grid.double_tempo(b, db, 4)
    assert len(doubled) == 2 * len(b) - 1 and abs(ddb[1] - truth[2]) < 1e-3
    halved, hdb = grid.halve_tempo(b, db, 4)
    assert abs(halved[1] - truth[2]) < 1e-3 and abs(hdb[1] - truth[8]) < 1e-3
