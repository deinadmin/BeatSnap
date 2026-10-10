# Building BeatSnap

Run from the repository root:

```sh
./Scripts/build-app.sh
```

This assembles and ad-hoc signs the app in a temporary directory, then publishes a clean
copy to `build/BeatSnap.app`. To also create `build/BeatSnap.dmg`, run
`./Scripts/build-app.sh --dmg`. Signing happens
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

- `--dmg`: also create the installer DMG.
- `BEATSNAP_APP_PATH`: override the app output path.
- `BEATSNAP_DMG_PATH`: override the installer output path (defaults to `BeatSnap.dmg` beside the app).
- `BEATSNAP_ENABLE_TEST_LICENSE=1`: enable the local CARLO and TRIAL test keys; for development only.
- `BEATSNAP_LICENSE_CONFIG`: override the Cryptolens client configuration plist path.

Standalone `create-dmg.sh` preserves the app signature; use the notarized build workflow below for releases.
Temporary volumes are detached on completion or failure. An existing DMG is replaced
only after the new image and its bundled app pass verification.

## Signed and notarized releases

`release.sh` now requires Developer ID signing and Apple notarization before uploading
its draft. `--skip-build` and `--dmg` require an already notarized DMG with a valid
stapled ticket and Gatekeeper acceptance. Local `build-app.sh` builds remain ad-hoc.

One-time setup:

1. Install a **Developer ID Application** certificate and its private key in your
   login Keychain (Xcode → Settings → Accounts → Manage Certificates).
2. Create a Keychain credential profile. This command prompts for your Apple ID,
   team ID, and an app-specific password; do not put the password in this repository:

   ```sh
   xcrun notarytool store-credentials "BeatSnap-notary"
   ```

3. Set these variables in your shell, or in the ignored `Scripts/web.env` used by
   `release.sh`:

   ```sh
   export BEATSNAP_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
   export BEATSNAP_NOTARY_PROFILE='BeatSnap-notary'
   ```

Build a notarized installer without uploading to the website:

```sh
./Scripts/build-app.sh --dmg --notarize
```

Or build, notarize, and upload a website draft:

```sh
./Scripts/release.sh 1.2.0
```

The build signs all bundled native tools before the app, uses secure timestamps and
Hardened Runtime, and retains Python runtime exceptions on the Python executables.
Signing failures stop the build. Test-license builds cannot be notarized.
The app is submitted and stapled first; the final signed DMG is then submitted and
stapled as well. This gives both artifacts offline tickets. Each submission waits
for Apple's result; rejected submissions print their log and submission ID.
Packaging/notarization failure preserves the previous DMG and prevents upload.
Notarization needs network access and may take several minutes or longer.

For an already signed artifact, `Scripts/notarize.sh /path/to/BeatSnap.app` (or `.dmg`)
can retry submission using the same Keychain profile. It does not sign the artifact.
After the first real notarized build, test audio import and a YouTube download on a
freshly downloaded installation to exercise the bundled runtime under Gatekeeper.

Notarization displays upload and processing progress and the submission ID. Waiting
stops after 30 minutes by default (`BEATSNAP_NOTARY_TIMEOUT=60m` overrides it); Apple
continues processing after a timeout. Check the printed `notarytool info` command
before submitting again. Failed or pending notarizations retain the signed artifact
in the printed temporary directory. Resume and staple those exact bytes with:

```sh
./Scripts/notarize.sh /path/printed/by/build/BeatSnap.app SUBMISSION-ID
```

For an app, package the successfully stapled artifact with `create-dmg.sh`, setting
`BEATSNAP_NOTARIZE=1` to sign and notarize the DMG. For a resumed DMG, upload it using
`release.sh VERSION --dmg /path/to/BeatSnap.dmg`. Remove the retained temporary
directory when finished.

## Automatic updates (Sparkle)

BeatSnap uses Sparkle's standard dialogs: it checks `appcast.php` daily, shows the release
notes, downloads the DMG, verifies its EdDSA signature, replaces the app and relaunches.

One-time setup:

```sh
./Scripts/sparkle-setup.sh
```

This creates (or reuses) the signing key in your login Keychain and writes the public key
to `BEATSNAP_SPARKLE_PUBLIC_KEY` in `Scripts/web.env`; `build-app.sh` embeds it as
`SUPublicEDKey`. Back up the private key — without it installed copies can never update:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/Desktop/beatsnap-sparkle-key
```

`release.sh` signs each DMG with `sign_update` and uploads the signature; the site's
`appcast.php` only lists releases that have one. The build number (`CFBundleVersion`)
must increase with every release. Updates require a Developer ID–signed build installed
in `/Applications`. The first Sparkle-enabled release only updates users from the next
release onward.
