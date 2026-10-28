#!/usr/bin/env zsh
# Downloads the Media3 ExoPlayer jars (and their runtime deps) into libs/. Run once; build.sh uses libs/*.jar.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p libs
G=https://dl.google.com/android/maven2
C=https://repo1.maven.org/maven2
M3=1.10.1

aar() { # aar <repo> <group/path> <artifact> <version>
    local f="libs/$3-$4.jar"
    [[ -f "$f" ]] && return
    local tmp=$(mktemp -d)
    curl -fsSL "$1/$2/$3/$4/$3-$4.aar" -o "$tmp/a.aar"
    unzip -q -o "$tmp/a.aar" classes.jar -d "$tmp"
    mv "$tmp/classes.jar" "$f"
    # Keep the library's consumer R8 rules next to it (build.sh feeds them to R8).
    if unzip -q -o "$tmp/a.aar" proguard.txt -d "$tmp" 2>/dev/null; then mv "$tmp/proguard.txt" "libs/$3-$4.pro"; fi
    rm -rf "$tmp"
}
jar() { # jar <repo> <group/path> <artifact> <version>
    local f="libs/$3-$4.jar"
    [[ -f "$f" ]] || curl -fsSL "$1/$2/$3/$4/$3-$4.jar" -o "$f"
}

for a in common container datasource decoder extractor database exoplayer exoplayer-hls; do
    aar $G androidx/media3 media3-$a $M3
done
jar $C com/google/guava guava 33.3.1-android
jar $C com/google/guava failureaccess 1.0.2
jar $C org/jetbrains/kotlin kotlin-stdlib 2.0.20
jar $G androidx/annotation annotation-jvm 1.8.0
aar $G androidx/annotation annotation-experimental 1.3.1
aar $G androidx/exifinterface exifinterface 1.3.6
# R8/D8 that understands Java 17 / Kotlin 2 class files (build-tools 32's d8 does not).
mkdir -p tools
[[ -f tools/r8.jar ]] || curl -fsSL "$G/com/android/tools/r8/8.13.22/r8-8.13.22.jar" -o tools/r8.jar
ls -la libs
