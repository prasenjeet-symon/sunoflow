#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SunoFlow"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"

echo "Building Swift executable (release)..."
swift build -c release

echo "Assembling ${APP_BUNDLE}..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Sign with a STABLE self-signed identity so macOS keeps the Microphone and
# Accessibility permissions across rebuilds. With ad-hoc signing (codesign -s -)
# the code identity changes every build, so TCC treats each rebuild as a new app
# and silently revokes previously granted permissions. Run ./setup-signing.sh once
# to create the "SunoFlow Self-Signed" identity in your login keychain.
SIGN_IDENTITY="SunoFlow Self-Signed"
if security find-identity -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "Code signing with stable identity: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "WARNING: '$SIGN_IDENTITY' not found. Falling back to ad-hoc signing."
    echo "         Permissions will reset on each rebuild. Run ./setup-signing.sh to fix."
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "Built $APP_BUNDLE"
