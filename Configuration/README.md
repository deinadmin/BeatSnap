# BeatSnap licensing

Copy `Cryptolens.example.plist` to `Cryptolens.plist` (gitignored) and set:

- `productID`: the BeatSnap product ID.
- `accessToken`: a client token restricted to that product, with only Activate and Deactivate permission. Never embed an administrator token: all bundled client configuration is extractable.
- `rsaPublicKey`: your Cryptolens RSA public key in XML format. A plist string must XML-escape angle brackets, as shown in the example; Xcode's property-list editor handles escaping automatically. Never include the RSA private key.

Run `./Scripts/build-app.sh`. It copies the configuration to the signed app's resources. A different input file can be selected with `BEATSNAP_LICENSE_CONFIG=/absolute/path/Cryptolens.plist`. Missing configuration produces an activation-only build with a clear error when activation is attempted. Running the raw SwiftPM executable does not load bundle resources.

The app uses Cryptolens API v3 Activate with String Sign, verifies RSA SHA-256 signatures using macOS Security, and checks product, key, device, expiry and signature age. The machine code is a SHA-256 hash of the Mac's platform UUID with a BeatSnap prefix. Set the product's maximum machine count to the desired seat limit; zero disables machine locking. Do not mask Key or MaxNoOfMachines in the access token's returned fields.

Expiration is enforced for every key. There is no implicit perpetual-license feature flag. Set the desired expiration in Cryptolens. The info card displays the exact expiry and remaining days.

The key and signed response are stored in macOS Keychain. Verification runs at startup and hourly while running. Network/server outages allow a previously verified receipt for at most seven days from its signed date, never beyond license expiry. Rejected or invalid responses lock the app. Time is checked every 30 seconds and at work-entry points. Offline revocation cannot be detected until reconnection or the signed lease expires; this is intentional. Local clock or binary tampering is outside this client-side enforcement model.

Remove License calls Deactivate to release this Mac's seat, then deletes the Keychain receipt and returns to activation. It requires connectivity; failures preserve the license and show an error. Already-running imports finish safely when a license expires or is removed; remaining queue items pause until activation. Activation cannot be dismissed into the library; the window can still be hidden/closed and the app quit normally.

Validation without a production key: run `swift test` for signed receipt, expiration, device/product matching and request-format tests. Before distributing, test a real valid, expired, blocked and seat-limited key; restart offline; remove and reactivate; verify pasted text works and Finder imports/drops are refused while locked. The build is ad-hoc signed today; use a stable distribution signing identity for predictable Keychain access across updates.

API references:
- https://app.cryptolens.io/docs/api/v3/Activate
- https://app.cryptolens.io/docs/api/v3/Deactivate
- https://github.com/Cryptolens/cryptolens-python/blob/master/licensing/internal.py


## Local test license

Enter `CARLO` in a debug build, or build the app with
`BEATSNAP_ENABLE_TEST_LICENSE=1 ./Scripts/build-app.sh`.
This activates locally without Cryptolens or network access, persists across launches,
and displays “Test license” with no expiry. Remove License clears the test activation.
Regular release builds ignore this test activation and require a real Cryptolens license.
Do not distribute builds made with the test-license flag.

If iCloud adds Finder metadata that prevents signing, set
`BEATSNAP_APP_PATH=/tmp/BeatSnap-Test/BeatSnap.app` to assemble outside iCloud.
