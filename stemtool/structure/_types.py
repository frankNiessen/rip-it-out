"""Small stand-ins for the parts of All-In-One's config and typing modules the model
code uses (the originals need hydra and omegaconf)."""

from __future__ import annotations

from dataclasses import dataclass
from types import SimpleNamespace

import torch

Config = SimpleNamespace  # the checkpoint's settings, with attribute access

HARMONIX_LABELS = ["start", "end", "intro", "outro", "break", "bridge", "inst", "solo", "verse", "chorus"]


@dataclass
class AllInOneOutput:
    logits_beat: torch.FloatTensor = None
    logits_downbeat: torch.FloatTensor = None
    logits_section: torch.FloatTensor = None
    logits_function: torch.FloatTensor = None
    embeddings: torch.FloatTensor = None


def to_config(d: dict) -> SimpleNamespace:
    return SimpleNamespace(**{k: to_config(v) if isinstance(v, dict) else v for k, v in d.items()})
