#!/bin/bash
# Copies the shared Fire TV web UI into assets/web/ (git-ignored) and loads vega-shim.js before it,
# so the Android and Vega builds keep one copy of the UI.
set -e
here="$(cd "$(dirname "$0")/.." && pwd)"
src="$here/../NucFlixFireTV/web"
dst="$here/assets/web"

rm -rf "$dst"
mkdir -p "$dst"
cp -R "$src"/. "$dst"/
cp "$here/web-shim/vega-shim.js" "$dst/"

# Insert the shim ahead of the first app script.
sed -i 's#<script src="firebase-config.js"></script>#<script src="vega-shim.js"></script>\n<script src="firebase-config.js"></script>#' "$dst/index.html"
grep -q 'vega-shim.js' "$dst/index.html" || { echo "sync-web: could not insert vega-shim.js into index.html" >&2; exit 1; }
echo "sync-web: copied $(find "$dst" -type f | wc -l) files to assets/web"
