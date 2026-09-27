"""Draws the iOS app icon from the desktop's (macos/make_icon.py). Needs Pillow:

    uv run --with pillow ios/make_icon.py

iOS rounds the corners itself and wants a full square without transparency, so this
takes the inside of the macOS rounded square (without its outline) and fills the rest.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "macos"))
import make_icon  # noqa: E402

img = make_icon.app_icon(1024)
ImageDraw.Draw(img).rounded_rectangle([100, 100, 924, 924], radius=185, outline=(*make_icon.DARK, 255), width=10)
inner = img.crop((104, 104, 920, 920)).resize((1024, 1024), Image.LANCZOS)
flat = Image.new("RGB", (1024, 1024), make_icon.DARK)
flat.paste(inner, mask=inner.split()[3])
flat.save(ROOT / "ios/RipItOut/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
