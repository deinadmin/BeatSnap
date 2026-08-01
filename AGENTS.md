# BeatSnap

A native macOS menubar app: paste a YouTube link (or drop a local audio file), get the audio
as a file in the beats folder, detect BPM and musical key on-device, and drag the result
straight into a DAW.

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
- **A file already in the beats folder is renamed, not copied.** Copying would leave the same
  audio twice in one folder. `BeatStore.stripAnalysisTag` also removes an existing
  " [140BPM F#min]" (and the " (2)" `uniqueURL` may have appended right after it) so re-analysing
  gives one tag, not two — but it deliberately won't touch titles that merely *look* tagged,
  like "…(MZLE) (2021)" or "Elfbaraddict612-2tone(148Bpm)".
- **All work goes through one serial queue.** `BeatLibrary.queue` holds YouTube links and
  dropped/opened files alike; a single `Task` (`drain()`) works through it one item at a time
  and is deliberately not tied to the panel, so a closed window keeps analysing. Only one
  worker may exist — `enqueue` starts one solely when `worker == nil`, and `drain` clears it
  when the queue empties. Failed items *stay* in the queue carrying their reason and are
  stepped over, because the panel is often closed when a failure happens and there'd otherwise
  be nowhere to report it. Queue depth is mirrored onto the menubar icon via
  `withObservationTracking`, which is one-shot and must be re-armed on every change.
- **Verify pipeline changes with `open -a BeatSnap <files>`**, which routes through
  `application(_:open:)` into the same queue — a real drag needs a real mouse. `FileManager`
  ignores `$HOME`, so an isolated run still writes the *real* `beats.json`; override the
  download folder with the argument domain (`-downloadDirectoryPath /tmp/...`) and back the
  index up first.
- **The drop target is the window and its content view, not a SwiftUI view.** A full-size
  `NSViewRepresentable` would sit above the hosting view and swallow every click; SwiftUI's
  `.dropDestination` can't refuse a drag *before* highlighting, and `FileRepresentation`
  hands over temporary copies. So `AudioDropHandler` is wired into `DropTargetEffectView`
  (the vibrancy view, an ancestor of the hosting view that AppKit's destination search walks
  up to) and into `BeatPanel` itself as a backstop. Drags with a non-nil `draggingSource` are
  refused — that's a beat row on its way *out* to a DAW.
- **yt-dlp must stay updatable.** It shipped 12 releases in 9 months because YouTube keeps
  breaking extractors. The bundled copy is only a floor; `Tools.updateYtDlpIfNeeded()`
  fetches newer zipapps into Application Support, deliberately *outside* the .app so the
  code signature stays valid. Never write updates into the bundle.
- **Don't use the PyInstaller onefile `yt-dlp_macos`.** It re-extracts 38 MB to /tmp on
  every invocation: 3.3s per call versus 0.3s for the zipapp.
- **Keep the playhead out of `BeatRowView`'s body.** The row reads only `isActive`/`isPlaying`
  from `AudioPreview`; `PlaybackBar` pulls `progress`/`duration` from the environment itself.
  Reading them one level up would make every visible row's body re-run 20x a second, since
  `@Observable` tracks whatever the body touched.
- **`AVAudioFile.read` throws `eofErr` (-39)** on the final short read of a compressed file
  instead of returning zero frames. Treat the throw as end-of-stream.
- Bundled Python needs `com.apple.security.cs.disable-library-validation` to load its own
  `.so` files under a signed parent; `build-app.sh` signs nested Mach-O files accordingly.

## Not verified automatically

Screen recording and Accessibility are denied to the terminal on this machine, so the UI
and the drag-into-DAW gesture cannot be checked programmatically — a real `NSDraggingSession`
needs a real mouse. Verify those by hand.
