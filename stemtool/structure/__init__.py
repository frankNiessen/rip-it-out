"""Song structure (intro, verse, chorus, bridge, ...) with All-In-One.

All-In-One (Taejun Kim and Juhan Nam, "All-In-One Metrical and Functional Structure
Analysis with Neighborhood Attentions on Demixed Audio", WASPAA 2023) is trained on
the Harmonix Set and labels sections of a song. Code and weights are MIT licensed
(https://github.com/mir-aidj/all-in-one, https://huggingface.co/taejunkim/allinone).

This package contains the parts needed for sections, adapted to run without its
heavier dependencies:
- allinone.py, dinat.py, utils.py: the model, unchanged except for imports.
- natten_torch.py: neighborhood attention in plain PyTorch, from Jonathan Feinberg's
  pull request mir-aidj/all-in-one#39 (MIT), instead of the NATTEN library.
- spectrogram.py: the madmom input features, reimplemented in NumPy.
See LICENSE in this folder.

The model reads the four Demucs tracks (bass, drums, other, vocals). The weights
(8 models, 1.4 MB each) are downloaded from Hugging Face on first use.
"""

from __future__ import annotations

import os
import threading
import urllib.request
from pathlib import Path

import numpy as np

from . import spectrogram as features
from .spectrogram import HOP, SAMPLE_RATE

WEIGHTS_URL = "https://huggingface.co/taejunkim/allinone/resolve/main/{}"
WEIGHTS = [
    "harmonix-fold0-0vra4ys2.pth", "harmonix-fold1-3ozjhtsj.pth", "harmonix-fold2-gmgo0nsy.pth",
    "harmonix-fold3-i92b7m8p.pth", "harmonix-fold4-1bql5qo0.pth", "harmonix-fold5-x4z5zeef.pth",
    "harmonix-fold6-x7t226rq.pth", "harmonix-fold7-qwwskhg6.pth",
]
INSTRUMENTS = ("bass", "drums", "other", "vocals")  # the order the model was trained with

_lock = threading.Lock()
_models: list | None = None


def cache_dir() -> Path:
    return Path(os.environ.get("RIPITOUT_CACHE") or Path.home() / ".cache" / "ripitout") / "allinone"


def _weights(name: str) -> Path:
    path = cache_dir() / name
    if not path.is_file():
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".part")
        with urllib.request.urlopen(WEIGHTS_URL.format(name), timeout=60) as r, tmp.open("wb") as out:
            out.write(r.read())
        if tmp.stat().st_size < 100_000:
            tmp.unlink()
            raise RuntimeError(f"Downloading the section model {name} failed")
        tmp.replace(path)
    return path


def _load() -> list:
    global _models
    with _lock:
        if _models is None:
            import torch

            from ._types import to_config
            from .allinone import AllInOne

            models = []
            for name in WEIGHTS:
                checkpoint = torch.load(_weights(name), map_location="cpu", weights_only=True)
                model = AllInOne(to_config(checkpoint["config"]))
                model.load_state_dict(checkpoint["state_dict"])
                model.eval()
                models.append(model)
            _models = models
        return _models


def _mono(x: np.ndarray) -> np.ndarray:
    return (x.mean(axis=1) if x.ndim == 2 else x).astype(np.float32)


def predict(stems: dict[str, np.ndarray], sample_rate: int) -> tuple[np.ndarray, np.ndarray]:
    """Per frame (100 per second): boundary probability, and label probabilities
    [10, frames], averaged over the 8 models."""
    import torch

    if sample_rate != SAMPLE_RATE:
        raise ValueError(f"Expected {SAMPLE_RATE} Hz audio")
    spec = np.stack([features.spectrogram(_mono(stems[name])) for name in INSTRUMENTS])
    x = torch.from_numpy(spec)[None]  # 1, instruments, frames, bands
    section, function = [], []
    with torch.no_grad():
        for model in _load():
            out = model(x)
            section.append(out.logits_section[0])
            function.append(out.logits_function[0])
    section_logits = torch.stack(section).mean(0)
    function_logits = torch.stack(function).mean(0)
    # section: [frames] (one class, squeezed by the model); function: [labels, frames]
    return torch.sigmoid(section_logits).reshape(-1).numpy(), torch.softmax(function_logits, dim=0).numpy()


def segments(stems: dict[str, np.ndarray], sample_rate: int) -> list[dict]:
    """[{"start", "end", "label"}] in seconds, labels as the model names them
    (intro, verse, chorus, bridge, inst, solo, break, outro; start and end are the
    silence before and after the music)."""
    from ._types import HARMONIX_LABELS
    from .postprocess import boundaries

    prob_section, prob_function = predict(stems, sample_rate)
    frames = boundaries(prob_section)
    duration = len(prob_section) * HOP / SAMPLE_RATE
    times = [0.0] + [f * HOP / SAMPLE_RATE for f in frames if f > 0] + [duration]
    splits = [f for f in frames if f > 0]
    labels = [HARMONIX_LABELS[int(p.mean(axis=1).argmax())] for p in np.split(prob_function, splits, axis=1)]
    return [{"start": round(a, 3), "end": round(b, 3), "label": lab}
            for a, b, lab in zip(times[:-1], times[1:], labels) if b > a]
