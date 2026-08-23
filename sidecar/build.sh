#!/bin/bash
# Freeze the SunoFlow macOS sidecar into a self-contained one-folder bundle.
#
#   ./build.sh
#   -> dist/SunoFlowSidecar/SunoFlowSidecar
#
# The output is a PyInstaller one-folder bundle (no Python/venv needed at
# runtime). It is meant to be copied into SunoFlow.app/Contents/Resources/sidecar/
# by release.sh during the release build. The Parakeet MLX model (~2.4 GB) is
# NOT bundled — it is downloaded on first run from the dashboard.
#
# Run this on an Apple-Silicon Mac (MLX is arm64-only). It creates a clean build
# venv (.venv-build) so it never disturbs the dev .venv.
set -euo pipefail
cd "$(dirname "$0")"

BUILD_VENV=".venv-build"
SPEC="sidecar.spec"
DIST="dist"
BUILD="build"

# Prefer Homebrew Python 3.12 (the dev .venv uses it; the pinned deps need
# >=3.10, but macOS ships a stub `python3` that points at system 3.9 which
# cannot satisfy them). Fall back to whatever `python3` resolves to on
# systems where 3.12 isn't installed via Homebrew.
if command -v python3.12 >/dev/null 2>&1; then
    PYBIN="python3.12"
else
    PYBIN="python3"
fi

echo "Using interpreter: $PYBIN ($($PYBIN --version 2>&1))"

echo "Creating clean build venv: $BUILD_VENV"
if [ -d "$BUILD_VENV" ]; then
    rm -rf "$BUILD_VENV"
fi
"$PYBIN" -m venv "$BUILD_VENV"
# shellcheck disable=SC1091
source "$BUILD_VENV/bin/activate"

echo "Installing requirements + PyInstaller..."
pip install --upgrade pip >/dev/null
pip install -r requirements.txt
pip install pyinstaller

echo "Freezing sidecar (this can take a few minutes)..."
pyinstaller --clean --noconfirm "$SPEC"

deactivate

BUNDLE="$DIST/SunoFlowSidecar"
if [ -x "$BUNDLE/SunoFlowSidecar" ]; then
    echo ""
    echo "✅ Built: $BUNDLE/SunoFlowSidecar"
    echo "   Copy this folder into SunoFlow.app/Contents/Resources/sidecar/ (release.sh)."
else
    echo "❌ Build failed: $BUNDLE/SunoFlowSidecar not found." >&2
    exit 1
fi