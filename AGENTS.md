# BeatSnap

A native macOS menubar app: paste a YouTube link, download the audio as WAV, detect BPM and
musical key on-device, and drag the result straight into a DAW.

Rewritten in Swift from an earlier Electron/Glaze prototype. Fully self-contained — no
Homebrew, no system Python, no external ffmpeg.

## Build & run

```bash
swift build -c release            # library + CLI + app executable
./Scripts/build-app.sh            # assemble + ad-hoc sign build/BeatSnap.app
open build/BeatSnap.app
```

`build-app.sh` downloads the bundled tools once into `Scripts/.cache` (CPython, the yt-dlp
zipapp, static ffmpeg), so the first build needs network and later ones don't.

## Verifying the analyzer

`beatsnap-analyze` is a development harness for the DSP, not shipped in the app.

```bash
.build/release/beatsnap-analyze <file.wav>              # analyze files
.build/release/beatsnap-analyze --validate beats.json   # score against known BPM/key
.build/release/beatsnap-analyze --debug <file.wav>      # per-stage key pipeline dump
.build/release/beatsnap-analyze --sweep beats.json      # tempo/key-profile parameter search
.build/release/beatsnap-analyze --sweepkey beats.json   # key framing/peak parameter search
```

`--validate` expects the original library index format (`[{title, filePath, bpm, key}]`).
Copy the WAVs off network storage first — analysis is ~0.07s per track, but reading them
from Google Drive dominated the runtime by 100x.

Current accuracy against the 16-track reference set: BPM 15/16 exact with zero octave
errors, key 13/16 exact (15/16 including relative/fifth neighbours).

## Architecture

- `Sources/BeatSnapAnalysis` — pure DSP, no AppKit. Decode (AVFoundation) → tempo
  (mel spectral-flux onset envelope, comb-filtered autocorrelation, log-normal tempo prior)
  and key (spectral peaks → whitening → HPCP chromagram → key-profile correlation).
- `Sources/BeatSnapApp` — AppKit shell (`NSStatusItem`, Carbon global hotkey, floating
  `NSPanel`) hosting a custom SwiftUI interface.
- `Sources/beatsnap-analyze` — the validation CLI above.

## Things that will bite you

- **Window normalization is not cosmetic.** Spectral whitening passes peaks above its
  frequency ceiling through with *raw* magnitudes while normalizing everything else to
  ~1.0. With an unnormalized (frame-size-scaled) spectrum, those few peaks swamp the
  chromagram — and 3400–3500 Hz folds onto pitch class A (3520 Hz is A7), so every track
  came back "A minor". `Windows.hann(_:normalized:)` scales by `2/sum(w)` to prevent this.
- **`setFrameAutosaveName` restores, not just saves.** If a frame is stored under that name
  it is applied on the spot, overriding the preceding `setContentSize`/`center()` — so
  editing the panel's launch size has *no effect* until the autosave name is bumped too
  (currently `BeatSnapPanel-380x770`). With no stored frame the call is a no-op, so the
  hardcoded size applies once and later user resizes persist.
- **Key naming is A-referenced** (`A, Bb, B, C, C#, D, Eb, E, F, F#, G, Ab`) to match the
  original library, which is why it reads "Ab minor" and never "G# minor".
- **yt-dlp must stay updatable.** It shipped 12 releases in 9 months because YouTube keeps
  breaking extractors. The bundled copy is only a floor; `Tools.updateYtDlpIfNeeded()`
  fetches newer zipapps into Application Support, deliberately *outside* the .app so the
  code signature stays valid. Never write updates into the bundle.
- **Don't use the PyInstaller onefile `yt-dlp_macos`.** It re-extracts 38 MB to /tmp on
  every invocation: 3.3s per call versus 0.3s for the zipapp.
- **`AVAudioFile.read` throws `eofErr` (-39)** on the final short read of a compressed file
  instead of returning zero frames. Treat the throw as end-of-stream.
- Bundled Python needs `com.apple.security.cs.disable-library-validation` to load its own
  `.so` files under a signed parent; `build-app.sh` signs nested Mach-O files accordingly.

## Not verified automatically

Screen recording and Accessibility are denied to the terminal on this machine, so the UI
and the drag-into-DAW gesture cannot be checked programmatically — a real `NSDraggingSession`
needs a real mouse. Verify those by hand.
