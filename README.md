# Rip It Out

**Rip the drums out of your music, play along with a click, and record yourself.**

Rip It Out is a practice tool for drummers. Paste a YouTube link or a whole playlist, and
it separates every song into a drums track and a "everything except drums" track, finds
every beat and bar, and builds a click that follows the band (even when the tempo drifts).
Then play along in your own window with a count-in, record your drums (and yourself on
camera) and mix your take with the band afterwards.

![The library, grouped into playlists](docs/library.png)

> **Made for macOS on Apple Silicon** (M1 or newer, macOS 13 Ventura or newer). The
> separation runs on the Mac's GPU. The engine also runs on Linux as a headless server
> with the UI in the browser, see [Linux](#linux-headless-server).

## Features

- **Drum separation** with Demucs, the best open model for this. Two styles: *Band* for
  rock, pop and funk, and *Electronic* for drum & bass, EDM and anything with heavy synth
  bass, which a plain separation mistakes for drums.
- **Beat and bar tracking** (beat_this) and a **click track** that sits on the real beats,
  as audio and as a MIDI file.
- **Play along** with a mixer for drums, band and click, a tempo view, a big beat and bar
  counter and a **count-in** of one or two bars.
- **Record** from any audio interface, for example an electronic drum module, optionally
  with video from a camera. Latency is measured once with a short calibration, so your
  take lines up with the song to the millisecond.
- **Review and export** your takes: your drums against the original, timing nudge,
  export as WAV or as MP4 video with the mix you like (click off, of course).
- **Library** in a plain folder you choose: groups (from playlist names or your own),
  search, queue with stop, no duplicates when you add a playlist again. Put it in
  iCloud Drive, Nextcloud or Dropbox to have it on your other devices.

![Count-in before the song starts](docs/play-countin.png)

## Install

1. Download `RipItOut-<version>.dmg` from the [Releases](../../releases) page.
2. Open it and drag **Rip It Out** to Applications.
3. The release builds are not signed with an Apple Developer ID yet, so macOS blocks the
   first start ("damaged" or "can't be opened"). Run this once in Terminal:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Rip It Out.app"
   ```

4. Start Rip It Out. The first song you add downloads the separation and beat models
   (about 400 MB, once).

Disk space: the app takes about 1.1 GB. Each song needs about 60 to 160 MB in your library
(lossless FLAC stems), takes with video more.

## How to use it

**1. Choose your library folder.** Open **Settings** and pick a folder. The default is
`~/Music/Rip It Out`. Everything the app makes lives there, one folder per song.

**2. Add songs.** In **Library**, paste a YouTube video or playlist link. Choose the group
(the playlist name is used if you leave it empty) and the music style, then press **Add**.
Each song takes one to two minutes on an M-series Mac. Songs already in your library are
skipped, so you can add the same playlist again later to pick up new songs. **Stop** ends
the song being processed, **Stop all** also empties the queue.

**3. Fix songs that came out drum heavy.** If the "no drums" track sounds almost empty
(typical for drum & bass or EDM, if you added it with the Band style), tick the songs in
the library and choose **Redo separation as Electronic**. This takes a minute and keeps beats, click
and takes.

**4. Play along.** In **Play**, pick a song, set the count-in and the levels (drums down,
band up, click to taste) and press Play or the space bar. Click on the tempo view to jump;
with a count-in, playback starts at the beginning of that bar.

The beat grid (click, bar numbers, count-in) is cleaned up automatically: the beat tracker
sometimes jumps between double and half tempo or loses a beat, and the app evens that out
while keeping the song's real tempo changes. If the "1" still sits on the wrong beat, or
the whole song is counted twice as fast or slow as you feel it, fix it next to the
transport: **Bar line ◂ ▸** moves every bar line by a beat, **×2** and **½** change the
tempo level, **Undo edits** goes back to the automatic grid.

If you unplug your audio interface, playback moves to the Mac's default output, and back
to the interface when you plug it in again.

**5. Record.** In **Record**, open **Setup** once:

- Choose your audio interface as input (an electronic drum kit connected by USB
  usually is one) and optionally a camera. On macOS you are asked to allow microphone
  and camera access.
- Press **Calibrate**: 20 clicks play, listen to the first 4 and hit a pad exactly with
  the rest. This measures the round trip delay of your setup.
- You hear your kit directly through your module or interface. The app never plays your
  input back, so there is no extra delay. Turn off any "USB loopback" on your module,
  otherwise the backing track ends up in your recording.

Then press **Record**. The count-in plays, the song starts, and the take is saved when
you press Stop or the song ends.

![Reviewing a take](docs/record.png)

**6. Review and export.** Pick a take on the right. It plays with its own fader
(**My drums**) next to the original drums, the band and the click. If your hits sit a
little early or late, move **Drums timing** until they line up and save; the video follows.
**Export audio** writes a WAV, **Export video** an MP4, both with the levels of the faders.

The **Library** menu has *Show Library in Finder*, *Update YouTube Downloader*, *Reset
YouTube Downloader*, *Restart Engine* and *Show Log*.

## What happens in the background

Processing is local: your recordings and the generated tracks are processed and stored on
your computer, and there is no Rip It Out server. The app connects to YouTube when it
downloads source audio, to the model publishers (Meta's `dl.fbaipublicfiles.com` for
Demucs, JKU Linz's `cloud.cp.jku.at` for beat_this) the first time it needs a model, and to PyPI only when you choose *Update YouTube
Downloader*.

| Step | What does it |
|---|---|
| Listing a playlist, downloading the audio | [yt-dlp](https://github.com/yt-dlp/yt-dlp), with [Deno](https://deno.com) for YouTube's JavaScript |
| Decoding to 44.1 kHz | [FFmpeg](https://ffmpeg.org) |
| Drums / no-drums separation | [Demucs](https://github.com/facebookresearch/demucs) `htdemucs_ft` on the Apple GPU ([PyTorch](https://pytorch.org) with MPS) |
| Electronic style | A harmonic/percussive split of the drums track that moves sustained, pitched sound (basses, synths) back to the band. The two tracks always add up to the original mix. |
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

### Library format

The library is plain files, so other tools (or instance a DAW) can use it:

```
<library>/
  some-song__<youtube id>/
    manifest.json      title, artist, group, bpm, beats, downbeats, file names
    drums.flac         the drums
    no_drums.flac      everything else
    click.flac         the click
    click.mid          the click as General MIDI percussion
    takes/<date>/
      take.json        timing and file list
      my_drums.flac    your recording, on the song's timeline
      raw.flac         the input exactly as captured
      video.mp4|webm   camera recording (optional)
      export.wav|mp4   last export (optional)
  .stemtool-work/      temporary, hidden
```

All FLAC files of a song (including `my_drums.flac`) have the same sample rate and length
and can be started together sample-accurately. `drums.flac + no_drums.flac` add up to the
original mix. A folder only counts as a song once `manifest.json` exists; songs are built
in the hidden work folder and moved into place in one step, so sync clients never pick up
half-written songs.

## Legal and copyright notice

Rip It Out is a practice tool for musicians. It can download audio from YouTube and
create local copies, separated tracks, click tracks, recordings and exports from that
audio. It accepts YouTube links only.

**Only download or process content that you are authorized to download and use.** You
are responsible for complying with applicable copyright law, the rights of the relevant
copyright and neighbouring-rights holders, and the terms that apply to the source
service. YouTube's Terms of Service restrict downloading and automated access unless
YouTube, and where applicable the rights holders, permit it, or applicable law does.

**Do not share or distribute separated tracks, downloaded audio, or exports containing
third-party copyrighted material** unless you have the necessary rights or permission.

Rip It Out does not circumvent DRM and does not grant you any rights to content obtained
from YouTube. The MIT license covers the software only, not any music you process with
it. Rip It Out is not affiliated with or endorsed by YouTube, Google, or any artist,
label, publisher or other rights holder.

## Build it yourself

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

**Releases:** the GitHub workflow (`.github/workflows/macos.yml`) builds a DMG on every
push to `main` (as a workflow artifact) and attaches it to a GitHub release for tags like
`v0.2.1`. Bump `__version__` in `stemtool/__init__.py` first. With a Developer ID
certificate in the repository secrets (listed in the workflow file) it also signs and
notarizes, and the `xattr` step is no longer needed.

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
| `stemtool/pipeline.py` | Download, decode, separate, track beats, write the song folder |
| `stemtool/separation.py` | Demucs and the electronic-style cleanup |
| `stemtool/beats.py`, `grid.py`, `click.py` | Beat tracking, grid cleanup and edits, click audio and MIDI |
| `stemtool/takes.py` | Recorded takes: alignment, video sync, export |
| `stemtool/static/index.html` | The whole UI (vanilla JS, Web Audio) |
| `desktop/` | Electron shell: starts the engine, window, permissions, menu |
| `macos/` | Build scripts for the app and DMG |

### Tests

```bash
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest
```

The tests use a generated song in a temporary folder, never your library. GitHub runs
them on every push (`.github/workflows/tests.yml`), without the ML models.

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

## Linux (headless server)

The engine runs on Linux with an NVIDIA GPU (CUDA) or on the CPU; you use the UI in a
browser on the same machine. Install Python 3.12, FFmpeg and [Deno](https://deno.com),
set up the virtual environment as in [Development](#development), and see
`deploy/stemtool.service` to run it as a systemd user service. On the CPU, set
`STEMTOOL_MODEL=htdemucs` to keep a song to a few minutes.

## Troubleshooting

- **Downloads fail:** YouTube probably changed something. Check for a newer Rip It Out
  release first. If there is none yet, *Library > Update YouTube Downloader* installs the
  newest yt-dlp (untested with your version; *Reset YouTube Downloader* undoes it). In
  development: `.venv/bin/pip install -U yt-dlp`.
- **Everything ended up in the drums track:** redo the song with the *Electronic* style.
- **The recording is silent:** check the input in Record > Setup (the level meter should
  move when you hit a pad) and allow microphone access in System Settings > Privacy &
  Security.
- **My hits are early or late:** run Calibrate again, or adjust *Drums timing* on the
  take.
- **Something else:** *Library > Show Log*.

## License

Rip It Out is MIT licensed, see [LICENSE](LICENSE). The app bundles third-party
components under their own licenses; see
[macos/THIRD_PARTY_NOTICES.md](macos/THIRD_PARTY_NOTICES.md).
