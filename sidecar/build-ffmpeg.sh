#!/bin/bash
# Build a self-contained, LGPL ffmpeg (with libopus) for the SunoFlow macOS
# sidecar bundle -> sidecar/vendor/ffmpeg/ffmpeg
#
# Why this exists: the app needs ffmpeg at runtime (parakeet-mlx shells out to it
# to decode audio; the cloud path encodes WAV -> Opus). Homebrew's ffmpeg is
# dynamically linked to a chain of Cellar dylibs, so it can't be copied into a
# distributable app — and prebuilt "static" macOS ffmpeg builds are typically
# GPL (they bundle x264/x265). So we build a minimal LGPL ffmpeg here:
#   * --disable-gpl --disable-nonfree  -> LGPL only, redistributable
#   * libopus built static from source -> the binary depends ONLY on macOS
#     system frameworks (verified with otool at the end), nothing from Homebrew.
#
# Runs on an Apple-Silicon Mac. Idempotent: skips the build if the vendored
# binary already exists and is self-contained (pass --force to rebuild).
set -euo pipefail
cd "$(dirname "$0")"

VENDOR="$(pwd)/vendor/ffmpeg"
BIN="$VENDOR/ffmpeg"

# Pinned source versions. Both are fetched over HTTPS from their official sites;
# checksums are verified below (filled in after the first successful build).
OPUS_VER="1.5.2"
FFMPEG_VER="7.1"
OPUS_SHA256="65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1"
FFMPEG_SHA256="40973d44970dbc83ef302b0609f2e74982be2d85916dd2ee7472d30678a7abe6"

FORCE="${1:-}"
if [ -x "$BIN" ] && [ "$FORCE" != "--force" ]; then
    if otool -L "$BIN" 2>/dev/null | tail -n +2 | grep -vqE '/usr/lib/|/System/'; then
        echo "warning: existing $BIN links non-system libs — rebuilding."
    else
        echo "ffmpeg already vendored at $BIN (use --force to rebuild):"
        "$BIN" -hide_banner -version | head -1
        exit 0
    fi
fi

command -v pkg-config >/dev/null 2>&1 || brew install pkg-config

JOBS="$(sysctl -n hw.ncpu)"
BUILD="$(mktemp -d)"
PREFIX="$BUILD/prefix"
trap 'rm -rf "$BUILD"' EXIT

verify() {  # <file> <expected-sha256>
    local got; got="$(shasum -a 256 "$1" | awk '{print $1}')"
    echo "  sha256($1) = $got"
    if [ -n "$2" ] && [ "$got" != "$2" ]; then
        echo "ERROR: checksum mismatch for $1 (expected $2)" >&2
        exit 1
    fi
}

echo "==> Building libopus $OPUS_VER (static)…"
cd "$BUILD"
curl -fsSL -o opus.tar.gz "https://downloads.xiph.org/releases/opus/opus-${OPUS_VER}.tar.gz"
verify opus.tar.gz "$OPUS_SHA256"
tar xf opus.tar.gz && cd "opus-${OPUS_VER}"
./configure --prefix="$PREFIX" --disable-shared --enable-static \
    --disable-doc --disable-extra-programs >/dev/null
make -j"$JOBS" >/dev/null && make install >/dev/null

echo "==> Building ffmpeg $FFMPEG_VER (LGPL, static libopus)…"
cd "$BUILD"
curl -fsSL -o ffmpeg.tar.xz "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz"
verify ffmpeg.tar.xz "$FFMPEG_SHA256"
tar xf ffmpeg.tar.xz && cd "ffmpeg-${FFMPEG_VER}"
# PKG_CONFIG_LIBDIR (not just _PATH) isolates pkg-config to our static-opus
# prefix, so it can't pick up Homebrew's libopus.dylib. --disable-autodetect
# stops ffmpeg auto-linking external libs it happens to find under Homebrew
# (libxcb / X11 / SDL2 / a dynamic opus); --disable-avdevice drops the capture
# layer that pulls the X11/AVFoundation-capture deps. Net: the binary links only
# macOS system frameworks + /usr/lib, with libopus baked in statically.
PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" ./configure \
    --prefix="$BUILD/out" \
    --disable-gpl --disable-nonfree \
    --enable-libopus \
    --disable-autodetect \
    --disable-avdevice \
    --enable-static --disable-shared \
    --disable-doc --disable-ffplay --disable-ffprobe \
    --disable-network --disable-debug \
    --pkg-config-flags=--static >/dev/null
make -j"$JOBS" ffmpeg >/dev/null

mkdir -p "$VENDOR"
cp ffmpeg "$BIN"
strip -S "$BIN" 2>/dev/null || true

# LGPL compliance: ship the license text + a note on versions and how to get the
# source, alongside the binary (the spec bundles these into the app).
cp COPYING.LGPLv2.1 "$VENDOR/COPYING.LGPLv2.1" 2>/dev/null || true
{
    echo "SunoFlow bundles ffmpeg ${FFMPEG_VER} + libopus ${OPUS_VER}, built from"
    echo "source under LGPL v2.1 (configured --disable-gpl --disable-nonfree"
    echo "--enable-libopus). No GPL components are included."
    echo
    echo "Source:"
    echo "  https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VER}.tar.xz"
    echo "  https://downloads.xiph.org/releases/opus/opus-${OPUS_VER}.tar.gz"
    echo "Build recipe: sidecar/build-ffmpeg.sh"
} > "$VENDOR/README.ffmpeg.txt"

echo "==> Done: $BIN"
"$BIN" -hide_banner -version | head -1
echo "--- linkage (must be system-only) ---"
otool -L "$BIN" | tail -n +2
if otool -L "$BIN" | tail -n +2 | grep -vqE '/usr/lib/|/System/'; then
    echo "ERROR: the binary links a non-system dylib — not self-contained." >&2
    exit 1
fi
echo "--- opus encoder present? ---"
"$BIN" -hide_banner -encoders 2>/dev/null | grep -i opus || {
    echo "ERROR: libopus encoder missing from the build." >&2; exit 1; }
