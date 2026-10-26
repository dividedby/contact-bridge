#!/bin/bash
# Builds a release .app, signs it, and installs it to ~/Applications/Contact Bridge.app.
# Signing identity: $CODESIGN_IDENTITY, else first "Apple Development" identity, else ad-hoc.
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE_ID="dev.dividedby.contactbridge"
APP_NAME="Contact Bridge"
EXEC_NAME="ContactBridgeApp"
INSTALL_DIR="$HOME/Applications"

plutil -lint Resources/Info.plist Resources/ContactBridge.entitlements

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

STAGE="build/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN_DIR/$EXEC_NAME" "$STAGE/Contents/MacOS/$EXEC_NAME"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
# Compile the Icon Composer bundle: Assets.car carries the Liquid Glass icon, AppIcon.icns the legacy fallback.
ICON_OUT="$(mktemp -d)"
trap 'rm -rf "$ICON_OUT"' EXIT
xcrun actool Resources/AppIcon.icon --compile "$ICON_OUT" --app-icon AppIcon --include-all-app-icons \
    --platform macosx --minimum-deployment-target 27.0 --enable-on-demand-resources NO \
    --output-partial-info-plist "$ICON_OUT/partial.plist" >"$ICON_OUT/actool.log" 2>&1 \
    || { cat "$ICON_OUT/actool.log" >&2; echo "actool failed to compile Resources/AppIcon.icon" >&2; exit 1; }
for produced in Assets.car AppIcon.icns; do
    [[ -f "$ICON_OUT/$produced" ]] || { cat "$ICON_OUT/actool.log" >&2; echo "actool did not produce $produced" >&2; exit 1; }
    cp "$ICON_OUT/$produced" "$STAGE/Contents/Resources/$produced"
done
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

# Google OAuth client ID/secret: bundled as GoogleOAuth.plist when the gitignored local copy exists. Its contents are
# never printed (all tool output below is discarded); only whether it is usable.
OAUTH_LOCAL="Config/GoogleOAuth.local.plist"
if [[ -f "$OAUTH_LOCAL" ]]; then
    plutil -lint "$OAUTH_LOCAL" >/dev/null 2>&1 || { echo "$OAUTH_LOCAL is not a valid plist" >&2; exit 1; }
    if grep -q "YOUR_" "$OAUTH_LOCAL"; then
        echo "WARNING: $OAUTH_LOCAL still has placeholder values; Google sign-in will not work." >&2
    fi
    cp "$OAUTH_LOCAL" "$STAGE/Contents/Resources/GoogleOAuth.plist"
    echo "Bundled GoogleOAuth.plist"
else
    echo "WARNING: $OAUTH_LOCAL not found; Google sign-in will not work. Copy Config/GoogleOAuth.example.plist to $OAUTH_LOCAL and fill it in." >&2
fi

SIGN_ARGS=(--force --options runtime --entitlements Resources/ContactBridge.entitlements)
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)"
fi

if [[ -n "$IDENTITY" ]]; then
    echo "Signing with identity: $IDENTITY"
    codesign "${SIGN_ARGS[@]}" --sign "$IDENTITY" "$STAGE"
else
    echo "Signing ad-hoc (no identity found); TCC grants may reset on rebuild"
    codesign "${SIGN_ARGS[@]}" --sign - \
        -r="designated => identifier \"$BUNDLE_ID\"" "$STAGE"
fi

codesign --verify --strict --verbose=2 "$STAGE"
# Notes go through Contacts' AppleScript dictionary: fail the build if the Apple Events entitlements did not make it in.
SIGNED_ENTITLEMENTS="$(codesign -d --entitlements :- "$STAGE" 2>/dev/null)"
for required in com.apple.security.automation.apple-events com.apple.security.temporary-exception.apple-events com.apple.AddressBook; do
    grep -q "$required" <<<"$SIGNED_ENTITLEMENTS" || { echo "Signed app is missing $required" >&2; exit 1; }
done
echo "Designated requirement:"
codesign -d -r- "$STAGE" 2>&1 | sed -n 's/^designated => /  /p'

mkdir -p "$INSTALL_DIR"
DEST="$INSTALL_DIR/$APP_NAME.app"
rm -rf "$DEST"
ditto "$STAGE" "$DEST"
echo "Installed: $DEST"
