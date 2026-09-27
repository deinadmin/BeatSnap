# Building BeatSnap

Run from the repository root:

```sh
./Scripts/build-app.sh
```

This assembles and ad-hoc signs the app in a temporary directory, publishes a clean
copy to `build/BeatSnap.app`, then creates `build/BeatSnap.dmg`. Signing happens
outside Finder/File Provider-managed folders to avoid metadata contaminating the bundle.
The published app is verified via a clean local copy because Desktop sync can
immediately restore FinderInfo to `.app` directories. The DMG’s app is verified
in its temporary volume, outside the synced Desktop.
The installer contains the app, an Applications shortcut, and a Retina background
showing where to drag the app. The first packaging run may prompt for permission
to control Finder, which saves the icon positions and background in the DMG.
Packaging requires a logged-in macOS desktop session.

To package an existing signed app without recompiling:

```sh
./Scripts/create-dmg.sh
./Scripts/create-dmg.sh /path/to/BeatSnap.app /path/to/BeatSnap.dmg
```

Build options:

- `BEATSNAP_SKIP_DMG=1`: build only the app, useful for development or headless builds.
- `BEATSNAP_APP_PATH`: override the app output path.
- `BEATSNAP_DMG_PATH`: override the installer output path (defaults to `BeatSnap.dmg` beside the app).
- `BEATSNAP_ENABLE_TEST_LICENSE=1`: enable the local CARLO and TRIAL test keys; for development only.
- `BEATSNAP_LICENSE_CONFIG`: override the Cryptolens client configuration plist path.

The DMG preserves the existing app signing approach; this script does not notarize it.
Temporary volumes are detached on completion or failure. An existing DMG is replaced
only after the new image and its bundled app pass verification.
