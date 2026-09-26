"""Finds the CUDA builds of the bundled PyTorch, for the installer's GPU download.

Run with the staged Python after the CPU build of PyTorch is installed (windows/build.sh):

    python gpu_wheels.py <index url> <gpu.json> <gpu.iss>

Writes the download URL, SHA-256 and size of the torch and torchaudio wheels that
match the bundled versions exactly, for 64-bit Windows and this Python: as JSON
(the app reads the folder name from it) and as defines for installer.iss.
"""

from __future__ import annotations

import json
import re
import sys
import urllib.request
from importlib import metadata
from pathlib import Path
from urllib.parse import unquote, urljoin

TAG = f"cp{sys.version_info.major}{sys.version_info.minor}"


def find(index: str, package: str, variant: str) -> dict:
    version = metadata.version(package).split("+")[0]
    page_url = f"{index.rstrip('/')}/{package}/"
    with urllib.request.urlopen(page_url, timeout=60) as r:
        page = r.read().decode()
    name = f"{package}-{version}+{variant}-{TAG}-{TAG}-win_amd64.whl"
    for href in re.findall(r'href="([^"]+)"', page):
        path, _, fragment = href.partition("#")
        if unquote(path.rsplit("/", 1)[-1]) == name and fragment.startswith("sha256="):
            url = urljoin(page_url, path)
            head = urllib.request.Request(url, method="HEAD")
            with urllib.request.urlopen(head, timeout=60) as r:
                size = int(r.headers["Content-Length"])
            return {"file": name, "url": url, "sha256": fragment.removeprefix("sha256="), "size": size}
    raise SystemExit(f"{name} is not in {page_url}")


def main() -> None:
    index, out, iss = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    variant = index.rstrip("/").rsplit("/", 1)[-1]  # cu128
    wheels = {p: find(index, p, variant) for p in ("torch", "torchaudio")}
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
