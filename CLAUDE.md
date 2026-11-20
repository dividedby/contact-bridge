# contact-bridge

macOS 27 menu-bar app (Swift 6.4, SwiftPM, no Xcode project) that backs up, dedupes and cleans up iCloud contacts and syncs them with the user's Google account. Logic lives in the `ContactBridgeCore` library (tested); `ContactBridgeApp` is the SwiftUI shell.

## Commands

- Test: `swift test -j 2` (Swift Testing, ~1200 tests, ~5 s warm).
- Lint: no separate linter; the format checks below are the lint step (`build-app.sh` also runs `plutil -lint` on the plists).
- Format check, as CI runs it (`.github/workflows/ci.yml`, `format.yml`): `xcrun swift-format format --in-place --recursive Sources Tests Package.swift && git diff --exit-code` for Swift, `shfmt -d .` for shell, `pnpm format:check` for the rest.
- Build and install the signed app: `scripts/build-app.sh` (installs to `~/Applications/Contact Bridge.app`).

## Gotchas

- Google sign-in needs `Config/GoogleOAuth.local.plist` (gitignored; copy `Config/GoogleOAuth.example.plist` and fill it in). `build-app.sh` only warns when it is missing and never prints its contents.
- Notes are read and written through Contacts' AppleScript dictionary, so the app needs the Apple Events entitlements in `Resources/ContactBridge.entitlements`; `build-app.sh` fails if the signed app lacks them.
- Without an "Apple Development" identity (or `$CODESIGN_IDENTITY`) the build signs ad hoc, and macOS may reset the Contacts permission on each rebuild.
- Test fixtures (`Tests/ContactBridgeCoreTests/Fixtures`) are byte-exact; `.prettierignore` skips them.
- Backups (`*.vcf`, `backups/`) are gitignored; never commit contact data.
- `design/` is untracked scratch (icon concepts). `pnpm format:check` flags it locally; CI never sees it.

## Where things live

| What                                                     | Where                               |
| -------------------------------------------------------- | ----------------------------------- |
| Pure logic: matching, merge, import, sync, photos, notes | `Sources/ContactBridgeCore/<area>/` |
| SwiftUI views and app wiring                             | `Sources/ContactBridgeApp/`         |
| Tests, named after the area they cover                   | `Tests/ContactBridgeCoreTests/`     |
