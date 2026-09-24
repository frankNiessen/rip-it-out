"""Draws the app icon and the menu bar icon. Needs Pillow, only at build time:

    uv run --with pillow macos/make_icon.py <output dir>

Writes icon-1024.png, which build.sh turns into AppIcon.icns.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

LIME = (198, 244, 50)
GREEN = (62, 232, 138)
LILAC = (198, 156, 245)
DARK = (7, 11, 16)


def rip_line(cx: float, top: float, bottom: float, zig: float, steps: int = 7) -> list[tuple[float, float]]:
    """A jagged vertical tear."""
    pts = []
    for i in range(steps + 1):
        y = top + (bottom - top) * i / steps
        pts.append((cx + (zig if i % 2 else -zig), y))
    return pts


def drum(draw: ImageDraw.ImageDraw, s: float, outline, width: float, fill=None) -> None:
    """A snare seen slightly from above, centred in a 1024 x 1024 box scaled by s."""
    left, right, top, bottom, ry = 232 * s, 792 * s, 400 * s, 690 * s, 92 * s
    if fill:
        draw.rectangle([left, top, right, bottom], fill=fill)
        draw.ellipse([left, bottom - ry, right, bottom + ry], fill=fill)
    draw.line([(left, top), (left, bottom)], fill=outline, width=int(width))
    draw.line([(right, top), (right, bottom)], fill=outline, width=int(width))
    draw.arc([left, bottom - ry, right, bottom + ry], 0, 180, fill=outline, width=int(width))
    draw.ellipse([left, top - ry, right, top + ry], outline=outline, width=int(width), fill=fill)
    for x in (330, 430, 594, 694):  # tension rods
        draw.line([(x * s, (top + ry * 0.9)), (x * s, bottom + ry * 0.8)], fill=outline, width=max(1, int(width * 0.45)))


def app_icon(size: int = 1024) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # macOS icon grid: an 824 px rounded square inside the 1024 canvas
    base = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bd = ImageDraw.Draw(base)
    bd.rounded_rectangle([100, 100, 924, 924], radius=185, fill=DARK, outline=(*LILAC, 150), width=6)
    img.alpha_composite(base)
    grid = Image.new("RGBA", (size, size), (0, 0, 0, 0))  # own layer, so it blends instead of punching holes
    gd = ImageDraw.Draw(grid)
    for i in range(132, 924, 48):
        gd.line([(i, 104), (i, 920)], fill=(120, 200, 140, 26), width=2)
        gd.line([(104, i), (920, i)], fill=(120, 200, 140, 26), width=2)
    img.alpha_composite(grid)

    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    drum(ImageDraw.Draw(glow), 1.0, (*LIME, 255), 34)
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(28)))
    body = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    drum(ImageDraw.Draw(body), 1.0, (*LIME, 255), 22, fill=(18, 40, 22, 255))
    img.alpha_composite(body)

    # the rip: a dark jagged gap through the drum with glowing edges
    tear = rip_line(512, 250, 820, 34)
    rip_glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(rip_glow).line(tear, fill=(*GREEN, 255), width=70, joint="curve")
    img.alpha_composite(rip_glow.filter(ImageFilter.GaussianBlur(22)))
    d = ImageDraw.Draw(img)
    d.line(tear, fill=(*LIME, 255), width=54, joint="curve")
    d.line(tear, fill=DARK, width=34, joint="curve")

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([100, 100, 924, 924], radius=185, fill=255)
    clipped = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    clipped.paste(img, (0, 0), mask)
    return clipped


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    out.mkdir(parents=True, exist_ok=True)
    app_icon().save(out / "icon-1024.png")
    print(f"Wrote icons to {out}")
