#!/bin/bash
# SunoFlow — production release build: notarized, stapled DMG.
#
# This is the counterpart to SunoFlowApp/build.sh (which is dev-only, ad-hoc
# signed). release.sh assembles a self-contained SunoFlow.app (Swift app +
# PyInstaller-frozen sidecar), signs it with a Developer ID Application
# certificate under the hardened runtime, notarizes it with Apple, staples
# the ticket, and packages it into a DMG (which is itself signed + notarized
# + stapled, as Apple recommends).
#
# Credentials (never committed) — read from the environment:
#   SUNOFLOW_SIGN_IDENTITY   e.g. "Developer ID Application: Prasenjeet (ABCDEF1234)"
#   SUNOFLOW_APPLE_ID         Apple ID for notarization
#   SUNOFLOW_TEAM_ID          Apple Developer team id
#   SUNOFLOW_NOTARY_PROFILE   (optional) notarytool keychain profile name; if set,
#                              used instead of APPLE_ID + app-specific password.
#   SUNOFLOW_APP_PW           app-specific password (only if NOTARY_PROFILE unset)
#
# If SUNOFLOW_SIGN_IDENTITY is unset or the identity isn't in the keychain, the
# script falls back to ad-hoc signing and SKIPS notarization — producing an
# unsigned DMG for local testing. This lets the script run on a dev box that
# doesn't yet have a Developer ID cert (per RELEASE_PLAN.md: the script is
# written now, the cert comes later).
#
# Usage:
#   ./release.sh                 # version from Info.plist (CFBundleShortVersionString)
#   ./release.sh 1.2.3           # explicit version
#   SUNOFLOW_SIGN_IDENTITY="Developer ID Application: ..." ./release.sh
#
# Output: SunoFlow-<version>.dmg (repo root), plus SunoFlow.app/ (intermediate).
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
APP_DIR="$ROOT/SunoFlowApp"
SIDECAR_DIR="$ROOT/sidecar"

APP_NAME="SunoFlow"
APP_BUNDLE="${APP_NAME}.app"
VERSION="${1:-}"
NOTARY_MODE="submit"   # submit | none

# ── Resolve version ─────────────────────────────────────────────────────────
if [ -z "$VERSION" ]; then
    # CFBundleShortVersionString from Info.plist (build.sh / release share this plist)
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        "$APP_DIR/Resources/Info.plist" 2>/dev/null || echo "1.0.0")
fi
DMG_NAME="SunoFlow-${VERSION}.dmg"
DMG_PATH="$ROOT/$DMG_NAME"
ZIP_PATH="$ROOT/${APP_BUNDLE}.zip"

echo "▶ SunoFlow release ${VERSION}"

# ── Resolve signing identity ─────────────────────────────────────────────────
SIGN_IDENTITY="${SUNOFLOW_SIGN_IDENTITY:-}"
NOTARIZE="no"
if [ -n "$SIGN_IDENTITY" ] \
   && security find-identity -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "▶ Signing identity: $SIGN_IDENTITY"
    NOTARIZE="yes"
else
    echo "⚠  No Developer ID identity found (SUNOFLOW_SIGN_IDENTITY unset or not in keychain)."
    echo "   Falling back to ad-hoc signing — NOTARIZATION WILL BE SKIPPED."
    echo "   The output DMG is unsigned and will trip Gatekeeper; for local testing only."
    SIGN_IDENTITY="-"   # ad-hoc
    NOTARIZE="no"
fi

# ── Pre-flight: notarization credentials (only if notarizing) ─────────────────
if [ "$NOTARIZE" = "yes" ]; then
    if [ -z "${SUNOFLOW_NOTARY_PROFILE:-}" ] && [ -z "${SUNOFLOW_APPLE_ID:-}" ]; then
        echo "❌ Notarization requested but no credentials: set SUNOFLOW_NOTARY_PROFILE"
        echo "   (preferred, via 'xcrun notarytool store-keychain') or SUNOFLOW_APPLE_ID"
        echo "   + SUNOFLOW_APP_PW + SUNOFLOW_TEAM_ID." >&2
        exit 1
    fi
    if [ -z "${SUNOFLOW_NOTARY_PROFILE:-}" ] && [ -z "${SUNOFLOW_TEAM_ID:-}" ]; then
        echo "❌ SUNOFLOW_TEAM_ID is required when not using a keychain profile." >&2
        exit 1
    fi
fi

# ── 1. Build the Swift executable (release) ──────────────────────────────────
echo "▶ Building Swift (release)…"
( cd "$APP_DIR" && swift build -c release )

BUILD_BIN="$APP_DIR/.build/release/$APP_NAME"
if [ ! -x "$BUILD_BIN" ]; then
    echo "❌ Swift build did not produce $BUILD_BIN" >&2
    exit 1
fi

# ── 2. Assemble the .app bundle ──────────────────────────────────────────────
echo "▶ Assembling ${APP_BUNDLE}…"
BUNDLE="$ROOT/$APP_BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

cp "$BUILD_BIN" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "$APP_DIR/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
if [ -f "$APP_DIR/Resources/AppIcon.icns" ]; then
    cp "$APP_DIR/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# ── 3. Bundle the frozen sidecar ─────────────────────────────────────────────
FROZEN="$SIDECAR_DIR/dist/SunoFlowSidecar"
SIDECAR_DEST="$BUNDLE/Contents/Resources/sidecar"
if [ ! -x "$FROZEN/SunoFlowSidecar" ]; then
    echo "▶ No frozen sidecar at $FROZEN — building it (sidecar/build.sh)…"
    ( cd "$SIDECAR_DIR" && ./build.sh )
    if [ ! -x "$FROZEN/SunoFlowSidecar" ]; then
        echo "❌ Sidecar freeze failed: $FROZEN/SunoFlowSidecar still missing." >&2
        exit 1
    fi
fi

echo "▶ Copying frozen sidecar into bundle…"
mkdir -p "$SIDECAR_DEST"
# ditto preserves resource forks + extended attrs better than cp -R for code.
ditto "$FROZEN" "$SIDECAR_DEST/SunoFlowSidecar"

# ── 4. Code-sign (inside-out) ────────────────────────────────────────────────
# Entitlements must attach to EVERY Mach-O that needs them. The frozen sidecar
# is a separate process with its own entitlements (it loads unsigned MLX/numba
# dylibs and allocates executable memory); the Swift app needs the mic
# entitlement. A single --deep pass on the outer .app only signs the main
# executable's entitlements, so we sign inside-out:
#   (a) the frozen sidecar bundle (deep) with full entitlements,
#   (b) the outer .app (shallow) with the same entitlements.
ENTITLEMENTS="$APP_DIR/Entitlements.plist"

echo "▶ Signing frozen sidecar (hardened runtime + entitlements)…"
codesign --force --deep --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$SIDECAR_DEST/SunoFlowSidecar"

echo "▶ Signing $APP_BUNDLE (hardened runtime + entitlements)…"
codesign --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$BUNDLE"

# Verify the signing (warnings are informational; errors fail below).
echo "▶ Verifying signature…"
codesign --verify --deep --strict --verbose=2 "$BUNDLE" 2>&1 | sed 's/^/   /' || true

# ── 5. Notarize the app ──────────────────────────────────────────────────────
# notarytool needs a zip (or the .app directly in newer Xcode). We zip first
# for stable, resubmittable artifacts and to match the DMG-notarize flow.
if [ "$NOTARIZE" = "yes" ]; then
    echo "▶ Zipping for notarization…"
    ditto -c -k --keepParent "$BUNDLE" "$ZIP_PATH"

    echo "▶ Notarizing app…"
    if [ -n "${SUNOFLOW_NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$ZIP_PATH" \
            --keychain-profile "$SUNOFLOW_NOTARY_PROFILE" --wait
    else
        xcrun notarytool submit "$ZIP_PATH" \
            --apple-id "$SUNOFLOW_APPLE_ID" \
            --team-id "$SUNOFLOW_TEAM_ID" \
            --password "$SUNOFLOW_APP_PW" --wait
    fi

    echo "▶ Stapling app ticket…"
    xcrun stapler staple "$BUNDLE"
    xcrun stapler validate "$BUNDLE"
    rm -f "$ZIP_PATH"
else
    echo "⏭  Skipping notarization (ad-hoc build)."
fi

# ── 6. Build the DMG ─────────────────────────────────────────────────────────
echo "▶ Creating ${DMG_NAME}…"
rm -f "$DMG_PATH"
# APFS, no filesystem layout frills — a single .app is fine to drag-copy from
# the mounted volume. -fs APFS keeps it modern; HFS+ is legacy.
hdiutil create -volname "$APP_NAME" -srcfolder "$BUNDLE" -fs APFS \
    -ov "$DMG_PATH"

# ── 7. Sign + notarize + staple the DMG ──────────────────────────────────────
if [ "$NOTARIZE" = "yes" ]; then
    echo "▶ Signing DMG…"
    codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"

    echo "▶ Notarizing DMG…"
    if [ -n "${SUNOFLOW_NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$SUNOFLOW_NOTARY_PROFILE" --wait
    else
        xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$SUNOFLOW_APPLE_ID" \
            --team-id "$SUNOFLOW_TEAM_ID" \
            --password "$SUNOFLOW_APP_PW" --wait
    fi

    echo "▶ Stapling DMG ticket…"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
else
    echo "⏭  Skipping DMG notarization (ad-hoc build)."
fi

echo ""
echo "✅ Done: $DMG_PATH"
if [ "$NOTARIZE" = "no" ]; then
    echo "   (UNSIGNED — ad-hoc, for local testing only. Set SUNOFLOW_SIGN_IDENTITY"
    echo "    + notarization credentials for a shippable release.)"
fi