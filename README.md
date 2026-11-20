# Contact Bridge

A macOS 27 menu-bar app that backs up, dedupes and cleans up iCloud contacts and syncs them with a Google account. iCloud is the source of truth; disagreements between the two sides go to a review list instead of being overwritten.

The app talks to Google directly from the Mac. There is no Contact Bridge server. The project site is [`dividedby/contact-bridge-site`](https://github.com/dividedby/contact-bridge-site).

## Build and run

Requires Swift 6.4 and macOS 27. The project is a SwiftPM package with no Xcode project.

- Test: `swift test -j 2`
- Build, sign and install: `scripts/build-app.sh` (installs to `~/Applications/Contact Bridge.app`)

Google sign-in needs `Config/GoogleOAuth.local.plist`. Copy `Config/GoogleOAuth.example.plist` and fill it in; the file is gitignored.

## Layout

- `Sources/ContactBridgeCore/`: the tested logic library (matching, merge, import, sync, photos, notes).
- `Sources/ContactBridgeApp/`: the SwiftUI shell.
- `Tests/ContactBridgeCoreTests/`: tests, named after the area they cover.

## Licence

MIT. See [`LICENSE`](./LICENSE).
