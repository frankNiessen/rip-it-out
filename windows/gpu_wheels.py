"""Finds the CUDA builds of the bundled PyTorch, for the installer's GPU download.

Run with the staged Python after the CPU build of PyTorch is installed (windows/build.sh):

    python gpu_wheels.py <gpu.json> <gpu.iss>

PyTorch publishes each version for a few CUDA versions only. This takes the oldest
CUDA that has the bundled version, since it works with the most drivers and cards.
Writes the download URL, SHA-256 and size of the torch and torchaudio wheels that
match the bundled versions exactly, for 64-bit Windows and this Python: as JSON
(the app reads the folder name from it) and as defines for installer.iss.
"""

from __future__ import annotations

import json
import re
import sys
import urllib.error
import urllib.request
from importlib import metadata
from pathlib import Path
from urllib.parse import unquote, urljoin

TAG = f"cp{sys.version_info.major}{sys.version_info.minor}"
INDEX = "https://download.pytorch.org/whl"
HEADERS = {"User-Agent": "pip/26 (rip-it-out build)"}
CUDA_VARIANTS = ["cu126", "cu128", "cu129", "cu130", "cu131", "cu132", "cu133", "cu134"]


def find(package: str, variant: str) -> dict | None:
    version = metadata.version(package).split("+")[0]
    page_url = f"{INDEX}/{variant}/{package}/"
    try:
        with urllib.request.urlopen(urllib.request.Request(page_url, headers=HEADERS), timeout=60) as r:
            page = r.read().decode()
    except urllib.error.HTTPError as exc:
        if exc.code in (403, 404):  # no such CUDA variant
            return None
        raise
    name = f"{package}-{version}+{variant}-{TAG}-{TAG}-win_amd64.whl"
    for href in re.findall(r'href="([^"]+)"', page):
        path, _, fragment = href.partition("#")
        if unquote(path.rsplit("/", 1)[-1]) == name and fragment.startswith("sha256="):
            url = urljoin(page_url, path)
            try:  # GET, not HEAD, which the CDN refuses; the body isn't read
                with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=60) as r:
                    size = int(r.headers["Content-Length"])
            except urllib.error.HTTPError as exc:
                print(f"{url}: {exc.code} {exc.reason}")
                return None
            return {"file": name, "url": url, "sha256": fragment.removeprefix("sha256="), "size": size}
    return None


def main() -> None:
    out, iss = Path(sys.argv[1]), Path(sys.argv[2])
    for variant in CUDA_VARIANTS:
        wheels = {p: find(p, variant) for p in ("torch", "torchaudio")}
        if all(wheels.values()):
            break
        print(f"{variant}: no build of the bundled torch and torchaudio")
    else:
        raise SystemExit(f"No CUDA build of torch {metadata.version('torch')} found in {INDEX}")
    torch_version = metadata.version("torch").split("+")[0]
    info = {"dir": f"torch-{torch_version}-{variant}", "wheels": wheels}
    out.write_text(json.dumps(info, indent=2), encoding="utf-8")
    total = sum(w["size"] for w in wheels.values())
    defines = {"GpuDir": info["dir"], "GpuMB": f"{total / 1e6:.0f}"}
    for key, prefix in (("torch", "Torch"), ("torchaudio", "Audio")):
        defines |= {f"{prefix}File": wheels[key]["file"], f"{prefix}Url": wheels[key]["url"],
                    f"{prefix}Sha": wheels[key]["sha256"]}
    iss.write_text("".join(f'#define {k} "{v}"\n' for k, v in defines.items()), encoding="utf-8")
    print(f"GPU download: {info['dir']}, {total / 1e6:.0f} MB")


if __name__ == "__main__":
    main()
