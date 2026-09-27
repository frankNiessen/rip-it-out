# Rip It Out for iPhone and iPad (preview)

Play along with the songs in your Rip It Out library and record yourself, on an iPhone
or iPad. The Mac (or Windows) app still does the heavy work: adding songs, separating
them, finding beats and sections. This app uses the library folder the desktop app
fills, synced through iCloud Drive, Nextcloud, Dropbox or any other Files provider.

## What it does

- **Library:** your songs by group, with search. Songs that are only in the cloud are
  downloaded when you open them.
- **Play along:** a channel strip per track (drums, bass, vocals, other, click) with its
  fader, **M** (mute) and **S** (solo: hear only the soloed tracks, the click keeps
  playing unless muted), the bar and beat counter, the tempo view with the song's
  sections, a count-in of one or two bars, and loops: tap a section to loop it, or
  **Loop** loops the section you are in; **‹ Start ›** and **‹ End ›** move either end
  by a bar. Mute and solo reset when the app restarts, the faders are kept.
- **Record:** from the built-in microphone, a headset or a USB audio interface. Latency
  is measured once with **Settings > Calibrate** (the same 20 clicks as on the desktop).
- **Takes:** saved into the song's `takes/` folder in the desktop's format
  (`take.json`, `raw.flac`, `my_drums.flac`), so the desktop app lists, plays and
  exports them too. Tap a take to play it against the song with its own fader
  (**My take**), or delete one you don't want. Takes recorded on the desktop show up
  here as well.

The app is for practice: everything that edits (the beat grid, sections, a take's
timing, level or name, exports, video) stays in the desktop app, and the phone picks up
the changes. The iOS app never changes a song's `manifest.json`, so two devices never
write the same file.

## Run it on your iPhone

Requirements: a Mac with Xcode 16 or newer, an iPhone or iPad with iOS 17 or newer, and
an Apple ID. A free account is enough to run the app on your own devices (the app then
has to be reinstalled from Xcode every 7 days); TestFlight and the App Store need a paid
Apple Developer account.

1. Open `ios/RipItOut.xcodeproj` in Xcode.
2. Select the **RipItOut** target, **Signing & Capabilities**, and pick your team (your
   Apple ID). If Xcode says the bundle identifier is taken, change
   `io.github.frankniessen.ripitout` to something of your own.
3. Connect your iPhone, choose it as the run destination and press **Run**. The first
   time, allow the developer on the phone in *Settings > General > VPN & Device
   Management*.
4. In the app, connect to your library:
   - **Nextcloud:** tap *Connect to Nextcloud* and enter the server address, your user
     name, an app password (Nextcloud in the browser: *Settings > Security > Devices &
     sessions > Create new app password*) and the library folder, e.g. `StemLibrary`.
     The app talks to the server directly (WebDAV): the Files app can't hand whole
     Nextcloud folders to other apps. Songs are downloaded when you open them and kept
     on the phone; takes are uploaded right after recording.
   - **iCloud Drive or On My iPhone:** tap *Choose a folder in Files*, for example
     *iCloud Drive > Rip It Out*. On the Mac, put the library in that folder with
     *Settings > Library folder*.

## Recording tips

- Use wired headphones or your interface's headphone output. Bluetooth headphones add a
  lot of delay, and with the speaker the song ends up in your recording.
- Calibrate once per input (the value is remembered per input device), and again if you
  change the buffer size or the interface.
- If a take sits a little early or late, fix its **Timing** in the desktop app, and
  calibrate again on the phone for the next takes.

## How it works

| Part | File |
|---|---|
| Library folder, bookmarks, iCloud downloads | `RipItOut/Library/LibraryStore.swift`, `Files.swift` |
| Nextcloud: WebDAV, the local mirror, uploads | `RipItOut/Library/Nextcloud.swift` |
| manifest.json and the beat grid (counter, count-in) | `RipItOut/Library/Manifest.swift`, `Grid.swift` |
| Playback: one AVAudioPlayerNode per track, all started at the same host time; loops as back-to-back segments | `RipItOut/Audio/PlayerEngine.swift` |
| Recording and calibration: a tap on the engine's input, placed on the song's timeline by host time and the calibrated latency | `RipItOut/Audio/Recorder.swift` |
| Take files (recording, deleting), same layout and math as `stemtool/takes.py` | `RipItOut/Library/Take.swift`, `TakeStore.swift`, `RipItOut/Audio/AudioIO.swift` |
| Screens | `RipItOut/Views/` |

A take is built in the app's temporary folder and moved into `takes/<id>/` in one step,
with `take.json` inside, so the desktop app and sync clients never see half a take.

## Tests

`xcodebuild test -project ios/RipItOut.xcodeproj -scheme RipItOut -destination 'platform=iOS Simulator,name=iPhone 16'`,
or **Product > Test** in Xcode. GitHub runs them on every push that changes `ios/`
(`.github/workflows/ios.yml`).
