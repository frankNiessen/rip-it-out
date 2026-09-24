"""Settings. The library folder comes from the settings file (changed in the app's
Settings tab), unless the STEMTOOL_LIBRARY environment variable overrides it.
Everything else is read from environment variables."""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

# Let PyTorch run any op the Apple GPU doesn't support on the CPU instead of failing.
# Must be set before torch is imported, which happens lazily after this module loads.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

SAMPLE_RATE = 44100
WORK_DIR_NAME = ".stemtool-work"  # hidden, so Nextcloud (and the app) ignore it

# Separation styles. "standard" is plain Demucs, right for band music. "electronic"
# adds a pass that pulls basses and synths back out of the drums stem (DnB, EDM).
STYLES = ("standard", "electronic")


@dataclass(frozen=True)
class Settings:
    library_dir: Path
    separation_model: str
    beat_checkpoint: str
    device_setting: str  # "auto", "cuda", "cpu", ...
    shifts: int

    @property
    def work_dir(self) -> Path:
        # Inside the library so the final rename is atomic (same filesystem).
        return self.library_dir / WORK_DIR_NAME

    @property
    def device(self) -> str:
        return resolve_device(self.device_setting)


@lru_cache(maxsize=None)
def resolve_device(setting: str) -> str:
    if setting != "auto":
        return setting
    import torch  # imported lazily: slow, and not needed to start the server

    if torch.cuda.is_available():
        return "cuda"
    if torch.backends.mps.is_available():  # Apple Silicon GPU
        return "mps"
    return "cpu"


APP_DIR_NAME = "Rip It Out"


def config_file() -> Path:
    """Where the settings file lives. The desktop app passes STEMTOOL_CONFIG."""
    if os.environ.get("STEMTOOL_CONFIG"):
        return Path(os.environ["STEMTOOL_CONFIG"]).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / APP_DIR_NAME / "settings.json"
    base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return base / "ripitout" / "settings.json"


def default_library() -> Path:
    return Path.home() / "Music" / APP_DIR_NAME


def library_locked() -> bool:
    """True when the environment sets the library, so the app can't change it."""
    return bool(os.environ.get("STEMTOOL_LIBRARY"))


def read_config() -> dict:
    try:
        return json.loads(config_file().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def write_config(changes: dict) -> None:
    path = config_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    data = read_config() | changes
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def load_settings() -> Settings:
    library = os.environ.get("STEMTOOL_LIBRARY") or read_config().get("library") or str(default_library())
    return Settings(
        library_dir=Path(library).expanduser().resolve(),
        separation_model=os.environ.get("STEMTOOL_MODEL", "htdemucs_ft"),
        beat_checkpoint=os.environ.get("STEMTOOL_BEAT_CHECKPOINT", "final0"),
        device_setting=os.environ.get("STEMTOOL_DEVICE", "auto"),
        shifts=int(os.environ.get("STEMTOOL_SHIFTS", "1")),
    )
