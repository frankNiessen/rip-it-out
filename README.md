# Rip It Out

Developer notes. **For users:** the website at
[frankniessen.github.io/rip-it-out](https://frankniessen.github.io/rip-it-out/) has the
downloads for Mac and Windows, what the app does and how to use it.

Rip It Out is a practice tool for musicians: it splits songs into drums, bass, vocals and
everything else, finds beats, bars and sections, builds a click that follows the band,
and lets you play along and record yourself. This repository has the engine (Python,
`stemtool/`), the desktop app (Electron, `desktop/`, built for macOS and Windows), the
iPhone and iPad app (`ios/`) and the website (`site/`).

| Part | Where | Notes |
|---|---|---|
| Engine and UI | `stemtool/` | FastAPI server; the whole UI is `stemtool/static/index.html` |
| Desktop app | `desktop/`, `macos/`, `windows/` | Electron around the engine, with its own Python |
| iPhone and iPad | `ios/` | SwiftUI, AVAudioEngine; see [ios/README.md](ios/README.md) |
| Website | `site/` | Published with GitHub Pages, see [Website](#website) |

## Development

```bash
python3.12 -m venv .venv
.venv/bin/pip install -r requirements.txt
brew install ffmpeg deno                       # the dev setup uses the system ones

# Browser only
.venv/bin/uvicorn stemtool.server:app --port 8765     # open http://localhost:8765

# In the Electron window
cd desktop && npm install && npm start
```

Browsers allow the microphone and camera only on `localhost` or HTTPS, so open
`http://localhost:8765`, not `0.0.0.0` or an IP address, if you want to record.

| File | Role |
|---|---|
| `stemtool/server.py` | FastAPI app and API |
| `stemtool/jobs.py` | Queue; each song runs in its own process so it can be stopped |
| `stemtool/pipeline.py` | Download (or read an imported file), decode, separate, track beats, find sections, write the song folder |
| `stemtool/localfiles.py` | Importing your own audio files |
| `stemtool/separation.py` | Demucs and the electronic-style cleanup |
| `stemtool/beats.py`, `grid.py`, `click.py` | Beat tracking, grid cleanup and edits, click audio and MIDI |
| `stemtool/takes.py` | Recorded takes: alignment, video sync, export, disk use |
| `stemtool/static/index.html` | The whole UI (vanilla JS, Web Audio) |
| `desktop/` | Electron shell: starts the engine, window, permissions, menu, app updates (`updates.js`) |
| `macos/` | Build scripts for the app and DMG |
| `ios/` | The iPhone and iPad app (SwiftUI, AVAudioEngine), see [ios/README.md](ios/README.md) |

### Tests

```bash
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest
```

The tests use a generated song in a temporary folder, never your library. GitHub runs
them on every push (`.github/workflows/tests.yml`), without the ML models. The updater
has its own tests: `node --test desktop/updates.test.js`.

### Settings (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `STEMTOOL_LIBRARY` | from Settings, else `~/Music/Rip It Out` | Library folder; when set, the Settings tab can't change it |
| `STEMTOOL_CONFIG` | `~/Library/Application Support/Rip It Out/settings.json` | Settings file |
| `STEMTOOL_MODEL` | `htdemucs_ft` | Demucs model (`htdemucs` is about 4x faster, a little worse) |
| `STEMTOOL_DEVICE` | `auto` | `auto`, `mps`, `cuda` or `cpu` |
| `STEMTOOL_SHIFTS` | `1` | Demucs shifts: higher is slightly better and slower |
| `STEMTOOL_BEAT_CHECKPOINT` | `final0` | beat_this checkpoint |
| `RIPITOUT_PORT` | `38765` | Port of the desktop app's engine |
| `RIPITOUT_UPDATE_URL` | GitHub's latest release | Where *Check for updates* looks (for testing the updater) |

## How it works

Processing is local: your recordings and the generated tracks are processed and stored on
your computer, and there is no Rip It Out server. The app connects to YouTube when it
downloads source audio, to the model publishers (Meta's `dl.fbaipublicfiles.com` for
Demucs, JKU Linz's `cloud.cp.jku.at` for beat_this, Hugging Face for the section model)
the first time it needs a model, to PyPI only when you choose *Update YouTube
Downloader*, and to GitHub only when you choose *Check for updates*.

| Step | What does it |
|---|---|
| Listing a playlist, downloading the audio | [yt-dlp](https://github.com/yt-dlp/yt-dlp), with [Deno](https://deno.com) for YouTube's JavaScript |
| Decoding to 44.1 kHz | [FFmpeg](https://ffmpeg.org) |
| Separation into drums, bass, vocals, other | [Demucs](https://github.com/facebookresearch/demucs) `htdemucs_ft` on the Apple GPU ([PyTorch](https://pytorch.org) with MPS) |
| Song sections | [All-In-One](https://github.com/mir-aidj/all-in-one) (Kim and Nam, 2023, trained on the Harmonix Set), run on the four tracks; borders snapped to bar lines. Included in `stemtool/structure` without its NATTEN and madmom dependencies (see the notes there). |
| Electronic style | A harmonic/percussive split of the drums track that moves sustained, pitched sound out of it: below 200 Hz to the bass track, above to other. The tracks always add up to the same mix. |
| Beats and downbeats | [beat_this](https://github.com/CPJKU/beat_this), then a cleanup that keeps one tempo level, fills lost beats and drops stray ones (`stemtool/grid.py`) |
| Click (audio and MIDI) | Rendered from the tracked beats |
| Recording | Web Audio (AudioWorklet) for sample-accurate audio, MediaRecorder for video. Takes are placed on the song's timeline using the calibrated latency. |
| Video sync | The sound in the video file is matched against the recorded audio (cross-correlation), so the camera's start delay doesn't matter |
| Export | NumPy mix, FFmpeg with Apple's VideoToolbox H.264 encoder |
| App | [Electron](https://www.electronjs.org) window around a local [FastAPI](https://fastapi.tiangolo.com) server on `localhost`, with its own Python ([python-build-standalone](https://github.com/astral-sh/python-build-standalone)) inside the app |

Each release bundles a pinned yt-dlp version it was tested with, and nothing updates on
its own. YouTube changes often, so when downloads stop working before the next release,
*Library > Update YouTube Downloader* installs the newest yt-dlp from PyPI (after asking,
wheels only) into `~/Library/Application Support/Rip It Out/site-packages`. The app itself
is never modified, and *Reset YouTube Downloader* goes back to the bundled version.
Installing a newer Rip It Out also drops such an update. Settings live in the same
folder, logs in `~/Library/Logs/Rip It Out`.

## Library format

The library is plain files, so other tools (for instance a DAW) can use it:

```
<library>/
  some-song__<youtube id>/
    manifest.json      title, artist, group, bpm, beats, downbeats, sections, file names
    drums.m4a          the drums          (.m4a, or .flac with a lossless setting)
    bass.m4a           the bass
    vocals.m4a         the vocals
    other.m4a          everything else
    click.flac         the click
    click.mid          the click as General MIDI percussion
    takes/<date>/
      take.json        timing and file list
      my_drums.flac    your take, on the song's timeline (the name dates from drums-only days)
      raw.flac         the input exactly as captured
      video.mp4|webm   camera recording (optional)
      export.wav|mp4   last export (optional)
  .stemtool-work/      temporary, hidden
```

All audio files of a song (including a take's `my_drums.flac`) have the same sample rate and
length and can be started together sample-accurately; that holds for the compressed AAC
files too, whose encoder delay is recorded in the file and removed by decoders. The four
tracks add up to the original mix (exactly with lossless files, audibly the same with
AAC). **Settings > Audio files** chooses the format: AAC 256 kbps (default, about 35 MB
per song), 16-bit or 24-bit FLAC; **Convert library** brings existing songs to the
chosen format. Songs made with Rip It Out 0.2 have two tracks (`drums`, `no_drums`)
until they are converted; `manifest.json` has `"schema": 2` for the four-track layout.
A folder only counts as a song once `manifest.json` exists; songs are built
in the hidden work folder and moved into place in one step, so sync clients never pick up
half-written songs.

## Building the desktop app

### macOS

Requirements: an Apple Silicon Mac, Xcode command line tools, `brew install uv node`.

```bash
git clone https://github.com/frankNiessen/rip-it-out.git
cd rip-it-out
macos/build.sh            # dist/Rip It Out.app and dist/RipItOut-<version>.dmg
macos/build.sh --no-dmg   # the app only
```

The first build takes about 10 minutes (it compiles FFmpeg), later ones about 3. A DMG
you build yourself opens without the `xattr` step.

What the build does (`macos/`): fetch a portable Python, install `requirements.txt` into
it, build FFmpeg from source without GPL parts (`build_ffmpeg.sh`), add Deno, draw the icon
(`make_icon.py`), wrap everything in the Electron app (`desktop/`) and sign it.

**CI:** `.github/workflows/macos.yml` builds a DMG on every push to `main` (as a workflow
artifact) and for release tags (see [Releases](#releases)). With a Developer ID
certificate in the repository secrets (listed in the workflow file) it also signs and
notarizes, and users no longer need the `xattr` step.

The update button trusts a release only through `RipItOut-<version>.update.json`: the DMG's
size and SHA-256, signed with an ed25519 key (`macos/sign_update.mjs`). The workflow writes
it on tags when the private key is in the `UPDATE_SIGNING_KEY` secret; the public key is in
`desktop/updates.js`. If you fork the project, make your own key pair and replace the public
key, otherwise your builds can't update themselves.

### Windows

Building it: `windows/build.sh` in Git Bash, with uv, Node.js, the GitHub CLI, 7-Zip and
Inno Setup 6. The GitHub workflow (`.github/workflows/windows.yml`) does this on every push
to `main` and attaches the installer to releases for tags.

## Releases

1. Bump `__version__` in `stemtool/__init__.py` and `MARKETING_VERSION` in
   `ios/RipItOut.xcodeproj/project.pbxproj`, and merge to `main`.
2. Create a release with a tag like `v0.8.0` on `main` (GitHub: *Releases > Draft a new
   release*, or push the tag).
3. The macOS and Windows workflows build on the tag and attach
   `RipItOut-<version>.dmg`, `RipItOut-<version>.update.json` and
   `RipItOut-Setup-<version>.exe` to the release. The website's download buttons pick
   up the newest release's files by those names, so keep them.

## Website

`site/index.html` is the whole page (the app's colors and fonts, no build step). The
workflow `.github/workflows/pages.yml` assembles it with the screenshots from `docs/`,
the fonts from `stemtool/static/fonts` and the app icon, and publishes it with GitHub
Pages on every push to `main` that touches them (or by hand: *Actions > Website > Run
workflow*). One-time setup: *Settings > Pages > Build and deployment > Source: GitHub
Actions*. The download buttons ask GitHub's API for the latest release when the page
loads and fall back to the releases page, so a new release needs no site rebuild.

To look at it locally:

```bash
mkdir -p /tmp/site/img /tmp/site/fonts && cp site/index.html /tmp/site/ && cp docs/*.png /tmp/site/img/ \
  && cp stemtool/static/fonts/*.woff2 /tmp/site/fonts/ && python3 -m http.server -d /tmp/site 8000
```

## Linux (headless server)

The engine runs on Linux with an NVIDIA GPU (CUDA) or on the CPU; you use the UI in a
browser on the same machine. Install Python 3.12, FFmpeg and [Deno](https://deno.com),
set up the virtual environment as in [Development](#development), and see
`deploy/stemtool.service` to run it as a systemd user service. On the CPU, set
`STEMTOOL_MODEL=htdemucs` to keep a song to a few minutes.

## Legal

Rip It Out can download audio from YouTube. Users are responsible for only processing
content they are authorized to use; the full notice is on the website and must stay
there and in the app. The MIT license covers the software only.

## License

Rip It Out is MIT licensed, see [LICENSE](LICENSE). The app bundles third-party
components under their own licenses; see
[macos/THIRD_PARTY_NOTICES.md](macos/THIRD_PARTY_NOTICES.md).
