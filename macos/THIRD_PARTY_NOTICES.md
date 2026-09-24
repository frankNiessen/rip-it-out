# Third-party components in Rip It Out.app

Rip It Out itself is MIT licensed (see `LICENSE`). The app bundles these
components, each under its own license. None of them is GPL.

| Component | License | Source |
|---|---|---|
| Electron (includes Chromium) | MIT, Chromium parts BSD and others, see `LICENSES.chromium.html` in the app's Resources | https://github.com/electron/electron |
| FFmpeg (ffmpeg, ffprobe), built without GPL parts | LGPL 2.1 or later, see `FFmpeg-COPYING.LGPLv2.1` | https://ffmpeg.org/releases/ (version in `ffmpeg -version`), built by `macos/build_ffmpeg.sh` |
| Deno | MIT | https://github.com/denoland/deno |
| Python (python-build-standalone) | PSF License and others | https://github.com/astral-sh/python-build-standalone |
| PyTorch, torchaudio | BSD-3-Clause and others | https://github.com/pytorch/pytorch |
| Demucs | MIT | https://github.com/facebookresearch/demucs |
| beat_this | MIT | https://github.com/CPJKU/beat_this |
| yt-dlp, yt-dlp-ejs | Unlicense | https://github.com/yt-dlp/yt-dlp |
| python-soxr (resampling, used by beat_this) | LGPL 2.1 or later | https://github.com/dofuuz/python-soxr |
| lameenc (MP3 encoding, a Demucs dependency) | LGPL 3.0 or later | https://github.com/chrisstaite/lameenc |
| FastAPI, Starlette, Uvicorn, python-multipart | MIT, BSD, Apache-2.0 | PyPI |
| NumPy, SciPy, soundfile, mido | BSD, MIT | PyPI |

The LGPL components are separate, replaceable files (the ffmpeg programs and
Python extension modules). Their source code is available at the links above.

yt-dlp's optional `mutagen` dependency (GPL) is deliberately not installed.

Model weights (Demucs, beat_this) are not included. They are downloaded from
their publishers on first use and stored in `~/.cache`.

The full license texts of the Python packages are in their `*.dist-info`
folders inside `Contents/Resources/python/lib/python3.12/site-packages`.
