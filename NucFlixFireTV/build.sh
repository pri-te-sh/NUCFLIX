#!/usr/bin/env zsh
# Builds and signs NucFlix.apk without Gradle: aapt2 -> javac -> R8 -> zipalign -> apksigner.
# Usage: ./build.sh [--debug] [--install]
#   --debug    debuggable build (enables chrome://inspect for the WebView UI)
#   --install  pushes it to the Fire TV and launches it
# Local settings live in local.properties (git-ignored): storePass=<keystore password>, firetv=<ip>:5555.
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_SDK:-$HOME/Library/Developer/Xamarin/android-sdk-macosx}"
BT="$SDK/build-tools/32.0.0"
JAR="$SDK/platforms/android-33/android.jar"
ADB="$(command -v adb || echo "$SDK/platform-tools/adb")"
prop() { sed -n "s/^$1=//p" local.properties 2>/dev/null || true; }
FIRETV="${FIRETV:-$(prop firetv)}"
OUT="${OUT:-build}"
PKG="com.pritesh.nucflix"
DEBUG=0 INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --debug) DEBUG=1 ;;
        --install) INSTALL=1 ;;
        *) echo "Unknown option: $arg (use --debug and/or --install)" >&2; exit 1 ;;
    esac
done

rm -rf "$OUT"
mkdir -p "$OUT/gen" "$OUT/classes" "$OUT/dex" "$OUT/assets"

# The 10-foot Netflix-style UI is served from assets/web via https://app.local/
cp -R web "$OUT/assets/web"

"$BT/aapt2" compile --dir res -o "$OUT/res.zip"
LINK_FLAGS=()
(( DEBUG )) && LINK_FLAGS+=(--debug-mode)
"$BT/aapt2" link "${LINK_FLAGS[@]}" -I "$JAR" --manifest AndroidManifest.xml --java "$OUT/gen" -A "$OUT/assets" \
    --proguard "$OUT/aapt-rules.pro" -o "$OUT/unsigned.apk" "$OUT/res.zip"

# Media3 ExoPlayer + deps live in libs/ (run ./fetch-libs.sh once).
[[ -f libs/media3-exoplayer-1.10.1.jar && -f tools/r8.jar ]] || ./fetch-libs.sh
LIBS=(libs/*.jar)
javac -source 8 -target 8 -Xlint:-options -encoding UTF-8 \
    -bootclasspath "$JAR" -classpath "$BT/core-lambda-stubs.jar:${(j/:/)LIBS}" -d "$OUT/classes" $(find src "$OUT/gen" -name '*.java')
# R8 shrinks Media3 + Guava + Kotlin down to what we use (the stock d8 in build-tools 32 can't read
# Java 17 / Kotlin 2 class files, so we use the standalone r8.jar from fetch-libs.sh).
(cd "$OUT/classes" && jar cf ../app-classes.jar .)
java -Xmx2g -cp tools/r8.jar com.android.tools.r8.R8 --release --min-api 26 --lib "$JAR" \
    --pg-conf proguard-rules.pro --pg-conf "$OUT/aapt-rules.pro" $(for f in libs/*.pro; do echo --pg-conf "$f"; done) \
    --output "$OUT/dex" "$OUT/app-classes.jar" "${LIBS[@]}"
(cd "$OUT/dex" && zip -q ../unsigned.apk classes*.dex)
# FFmpeg audio decoders (DTS, TrueHD...) the Fire TV lacks, built by tools/build-ffmpeg.sh.
mkdir -p "$OUT/native" && cp -R jniLibs "$OUT/native/lib"
(cd "$OUT/native" && zip -q -r ../unsigned.apk lib)

"$BT/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
# Signing key: keystore.jks + storePass in local.properties (both git-ignored). The first build creates them with a
# random password; keep both backed up, a TV app signed with another key has to be uninstalled first.
if [[ ! -f keystore.jks ]]; then
    pass="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
    keytool -genkeypair -keystore keystore.jks -storetype PKCS12 -storepass "$pass" \
        -alias nucflix -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=NucFlix" >/dev/null
    (umask 077; print "storePass=$pass" >> local.properties)
fi
export STORE_PASS="${NUCFLIX_KEYSTORE_PASS:-$(prop storePass)}"
[[ -n "$STORE_PASS" ]] || { echo "No keystore password: add storePass=... to local.properties or set NUCFLIX_KEYSTORE_PASS" >&2; exit 1; }
"$BT/apksigner" sign --ks keystore.jks --ks-pass env:STORE_PASS --out "$OUT/NucFlix.apk" "$OUT/aligned.apk"
echo "Built $OUT/NucFlix.apk"

if (( INSTALL )); then
    [[ -n "$FIRETV" ]] || { echo "Set FIRETV=<ip>:5555 or add firetv=<ip>:5555 to local.properties" >&2; exit 1; }
    "$ADB" connect "$FIRETV" >/dev/null
    "$ADB" -s "$FIRETV" install -r --no-incremental "$OUT/NucFlix.apk"
    "$ADB" -s "$FIRETV" shell am start -n "$PKG/.MainActivity"
fi
