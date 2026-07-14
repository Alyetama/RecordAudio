<h1 align="center">RecordAudio</h1>

<p align="center">Record whatever your Mac is playing (not the microphone) to small, good-quality AAC files. Runs as a window, from the menu bar, or both.</p>

<p align="center">
  <img src="docs/mockup.png" alt="RecordAudio" width="720">
</p>

<p align="center">
  <a href="https://github.com/Alyetama/RecordAudio/releases/latest/download/RecordAudio.dmg"><b>Download for macOS</b></a>
  &nbsp;·&nbsp; macOS 13+ &nbsp;·&nbsp; Apple Silicon
</p>

---

## What it does

It records the sound coming out of your Mac (a browser tab, a music app, a call) instead of the mic. Files are AAC in an `.m4a`, so they stay small: about 1 MB a minute on the Balanced preset, less on Small, more on High.

A few things it can do beyond just recording:

- Capture one specific app instead of the whole system mix.
- Live in a normal window, the menu bar, or both, and hide its Dock icon if you want it out of the way.
- Trim a recording afterward in a small waveform editor. Drag the ends, click anywhere to scrub, play it back, then save. The trim copies the audio as-is, so there's no re-encode and no quality loss.
- Transcribe a recording to a text file that lands next to it. This one runs Whisper (the tiny model) on your machine, so it needs `whisper-cli` installed (`brew install whisper-cpp`); the model itself, about 75 MB, downloads the first time you use it.

No BlackHole, no Soundflower, no virtual devices. It uses Apple's ScreenCaptureKit, which is also why macOS asks for Screen Recording permission the first time (more on that below).

## First launch (opening an unsigned app)

RecordAudio isn't signed with an Apple Developer ID, so macOS blocks it the first
time. Any one of these gets you in, and you only have to do it once:

1. **Right-click to open** — in Finder, Control-click (right-click)
   **RecordAudio.app** → **Open**, then **Open** again in the dialog.
2. **Privacy & Security** — if it's still blocked on newer macOS, open
   **System Settings → Privacy & Security**, scroll down, and click
   **Open Anyway** next to the RecordAudio message, then confirm with **Open**.
3. **Terminal** — or clear the quarantine flag:
   ```bash
   /usr/bin/xattr -dr com.apple.quarantine /Applications/RecordAudio.app
   ```

> The first time you hit **Record**, macOS also asks for **Screen Recording**
> permission. That's the only way macOS lets an app capture system audio, so
> turn RecordAudio on under *System Settings → Privacy & Security → Screen Recording*.

## Build from source

```bash
./Icon/build_icon.sh   # (re)generate the app icon (optional)
./build.sh             # compile a signed RecordAudio.app into ./build
open build/RecordAudio.app
```

Requires macOS 13+ and the Swift toolchain (Xcode or Command Line Tools). See
the source in [`Sources/`](Sources/).

## License

[MIT](LICENSE) © 2026 Alyetama
