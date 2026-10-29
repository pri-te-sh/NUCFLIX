#!/bin/zsh
# Builds libffmpegJNI.so (Media3 1.10.1's FFmpeg audio decoder) into jniLibs/ for the Fire TV app.
#
# Fire TVs have no DTS / TrueHD decoder (they can only pass those through to an AV receiver), so
# ExoPlayer would play such titles without sound. This compiles just those FFmpeg audio decoders,
# LGPL-only (no --enable-gpl / --enable-nonfree), and Media3's JNI glue around them.
#
# Needs: Android NDK r27c, FFmpeg 6.1.2 source, Media3 1.10.1's libraries/decoder_ffmpeg (all fetched into
# $BUILD below if missing, ~1 GB). Output (committed, so normal builds don't need the NDK):
#   jniLibs/armeabi-v7a/libffmpegJNI.so, jniLibs/arm64-v8a/libffmpegJNI.so
# The Java side lives in src/androidx/media3/decoder/ffmpeg/ (copied from the same Media3 tag).
set -euo pipefail
cd "${0:A:h}/.."
APP="$PWD"
BUILD="${NUCFLIX_NATIVE_BUILD:-$HOME/Personal/IPTV-build}"
NDK="$BUILD/android-ndk-r27c"
FFMPEG="$BUILD/ffmpeg-6.1.2"
MEDIA3="$BUILD/media3/libraries/decoder_ffmpeg"
MIN_API=26
DECODERS=(dca truehd mlp ac3 eac3 mp2)

mkdir -p "$BUILD"
[[ -d "$NDK" ]] || { curl -fL -o "$BUILD/ndk.zip" https://dl.google.com/android/repository/android-ndk-r27c-darwin.zip && unzip -q "$BUILD/ndk.zip" -d "$BUILD" && rm "$BUILD/ndk.zip"; }
[[ -d "$FFMPEG" ]] || { curl -fL https://ffmpeg.org/releases/ffmpeg-6.1.2.tar.xz | tar xJ -C "$BUILD"; }
[[ -d "$MEDIA3" ]] || {
    git clone -q --depth 1 --branch 1.10.1 --filter=blob:none --sparse https://github.com/androidx/media.git "$BUILD/media3"
    (cd "$BUILD/media3" && git sparse-checkout set libraries/decoder_ffmpeg)
}

TC="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
JOBS="$(sysctl -n hw.ncpu)"
COMMON=(--target-os=android --enable-static --disable-shared --disable-doc --disable-programs --disable-everything
        --disable-avdevice --disable-avformat --disable-swscale --disable-postproc --disable-avfilter --disable-symver
        --enable-swresample --disable-v4l2-m2m --disable-vulkan --enable-pic)
for d in $DECODERS; do COMMON+=(--enable-decoder=$d); done

build_abi() {
    local abi=$1 arch=$2 cpu=$3 triple=$4; shift 4
    local out="$BUILD/ffmpeg-libs/$abi"
    (cd "$FFMPEG" && ./configure --prefix="$out" --libdir="$out/lib" --incdir="$out/include" --arch=$arch --cpu=$cpu \
        --cross-prefix="$TC/$triple$MIN_API-" --nm="$TC/llvm-nm" --ar="$TC/llvm-ar" --ranlib="$TC/llvm-ranlib" \
        --strip="$TC/llvm-strip" "$@" $COMMON >/dev/null \
        && make -j$JOBS >/dev/null && make install-libs install-headers >/dev/null && make distclean >/dev/null)
    grep -q "^#define CONFIG_GPL 0" "$FFMPEG/config.h" 2>/dev/null || true
    mkdir -p "$APP/jniLibs/$abi"
    "$TC/$triple$MIN_API-clang++" -shared -fPIC -O2 -std=c++11 -I"$out/include" \
        "$MEDIA3/src/main/jni/ffmpeg_jni.cc" "$out/lib/libswresample.a" "$out/lib/libavcodec.a" "$out/lib/libavutil.a" \
        -landroid -llog -lm -static-libstdc++ -Wl,-Bsymbolic -Wl,-z,max-page-size=16384 -Wl,--gc-sections \
        -o "$APP/jniLibs/$abi/libffmpegJNI.so"
    "$TC/llvm-strip" --strip-unneeded "$APP/jniLibs/$abi/libffmpegJNI.so"
    echo "built jniLibs/$abi/libffmpegJNI.so"
}

build_abi armeabi-v7a arm armv7-a armv7a-linux-androideabi --extra-cflags="-march=armv7-a -mfloat-abi=softfp"
build_abi arm64-v8a aarch64 armv8-a aarch64-linux-android

# Java side, same tag (Apache 2.0).
mkdir -p "$APP/src/androidx/media3/decoder/ffmpeg"
for f in FfmpegAudioRenderer FfmpegAudioDecoder FfmpegLibrary FfmpegDecoderException; do
    # Checker Framework annotations are compile-time only and not on this app's classpath.
    sed -e '/^import org\.checkerframework\./d' -e 's/@MonotonicNonNull //g' \
        "$MEDIA3/src/main/java/androidx/media3/decoder/ffmpeg/$f.java" > "$APP/src/androidx/media3/decoder/ffmpeg/$f.java"
done
