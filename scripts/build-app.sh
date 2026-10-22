#!/bin/bash
# Builds a release .app, signs it, and installs it to ~/Applications/Contact Bridge.app.
# Signing identity: $CODESIGN_IDENTITY, else first "Apple Development" identity, else ad-hoc.
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE_ID="dev.dividedby.contactbridge"
APP_NAME="Contact Bridge"
EXEC_NAME="ContactBridgeApp"
INSTALL_DIR="$HOME/Applications"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

STAGE="build/$APP_NAME.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN_DIR/$EXEC_NAME" "$STAGE/Contents/MacOS/$EXEC_NAME"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"

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
echo "Designated requirement:"
codesign -d -r- "$STAGE" 2>&1 | sed -n 's/^designated => /  /p'

mkdir -p "$INSTALL_DIR"
DEST="$INSTALL_DIR/$APP_NAME.app"
rm -rf "$DEST"
ditto "$STAGE" "$DEST"
echo "Installed: $DEST"
