# Third-party components in Rip It Out for Windows

Rip It Out itself is MIT licensed (see `LICENSE`). The app bundles these
components, each under its own license.

This list describes the main components. The exact versions and licenses of all
Python packages in a given release are in `PYTHON_PACKAGES.md` next to this file,
generated when that release was built. The build stops if a bundled Python package
is GPL or AGPL licensed, or if the bundled ffmpeg is not an LGPL build.

| Component | License | Source |
|---|---|---|
| Electron (includes Chromium) | MIT, Chromium parts BSD and others, see `LICENSES.chromium.html` in the app folder | https://github.com/electron/electron |
| FFmpeg (ffmpeg, ffprobe), LGPL build without GPL or nonfree parts | LGPL, see `FFmpeg-LICENSE.txt` | https://ffmpeg.org, build from https://github.com/BtbN/FFmpeg-Builds (version in `ffmpeg -version`), checked by `windows/fetch_ffmpeg.sh` |
| Deno | MIT | https://github.com/denoland/deno |
| Python (python-build-standalone) | PSF License and others | https://github.com/astral-sh/python-build-standalone |
| PyTorch, torchaudio (CPU build) | BSD-3-Clause and others | https://github.com/pytorch/pytorch |
| Demucs | MIT | https://github.com/facebookresearch/demucs |
| beat_this | MIT | https://github.com/CPJKU/beat_this |
| All-In-One (model code in `stemtool/structure`; weights downloaded on first use) | MIT, see `stemtool/structure/LICENSE` | https://github.com/mir-aidj/all-in-one, weights https://huggingface.co/taejunkim/allinone |
| Neighborhood attention in plain PyTorch (`natten_torch.py`), from pull request mir-aidj/all-in-one#39 | MIT | https://github.com/mir-aidj/all-in-one/pull/39 |
| yt-dlp, yt-dlp-ejs | Unlicense | https://github.com/yt-dlp/yt-dlp |
| python-soxr (resampling, used by beat_this) | LGPL 2.1 or later | https://github.com/dofuuz/python-soxr |
| lameenc (MP3 encoding, a Demucs dependency) | LGPL 3.0 or later | https://github.com/chrisstaite/lameenc |
| FastAPI, Starlette, Uvicorn, python-multipart | MIT, BSD, Apache-2.0 | PyPI |
| Archivo and Martian Mono fonts (in `stemtool/static/fonts`) | SIL Open Font License 1.1 | https://github.com/Omnibus-Type/Archivo, https://github.com/evilmartians/mono |
| NumPy, SciPy, soundfile, mido | BSD, MIT | PyPI |

The LGPL components are separate, replaceable files (the ffmpeg programs and
Python extension modules). Their source code is available at the links above.

yt-dlp's optional `mutagen` dependency (GPL) is deliberately not installed.

Model weights (Demucs, beat_this, All-In-One) are not included. They are downloaded from
their publishers on first use and stored in `.cache` in your user folder.

The full license texts of the Python packages are in their `*.dist-info`
folders inside `resources\python\Lib\site-packages` in the app folder.

GPU acceleration is not part of the app. On PCs with an NVIDIA graphics card, Setup
offers to download the CUDA build of PyTorch from pytorch.org into
`%LOCALAPPDATA%\Rip It Out\gpu`. That build includes NVIDIA's CUDA runtime libraries
(cuBLAS, cuFFT, cuDNN and others) under NVIDIA's license for redistributable
components, see https://docs.nvidia.com/cuda/eula/.
