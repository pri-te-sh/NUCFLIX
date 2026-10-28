#!/usr/bin/env bash
# Downloads MobileVLCKit (the iOS player engine) from VideoLAN into Frameworks/.
# The framework is ~300 MB unpacked, so it is not committed to git.
set -euo pipefail

VERSION="3.7.3-319ed2c0-79128878"
SHA256="0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9"
URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-${VERSION}.tar.xz"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Frameworks/MobileVLCKit.xcframework"

if [[ -d "$DEST" && "${1:-}" != "--force" ]]; then
    echo "MobileVLCKit already present at $DEST (pass --force to replace it)"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading MobileVLCKit $VERSION..."
curl -fL --progress-bar -o "$TMP/vlckit.tar.xz" "$URL"
echo "$SHA256  $TMP/vlckit.tar.xz" | shasum -a 256 -c -

tar -xJf "$TMP/vlckit.tar.xz" -C "$TMP" MobileVLCKit-binary/MobileVLCKit.xcframework MobileVLCKit-binary/COPYING.txt
mkdir -p "$ROOT/Frameworks"
rm -rf "$DEST"
mv "$TMP/MobileVLCKit-binary/MobileVLCKit.xcframework" "$DEST"
mv "$TMP/MobileVLCKit-binary/COPYING.txt" "$ROOT/Frameworks/VLCKit-COPYING.txt"
echo "MobileVLCKit installed in Frameworks/"
