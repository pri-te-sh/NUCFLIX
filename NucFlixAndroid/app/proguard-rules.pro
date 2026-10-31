# FFmpeg audio decoder (NucFlixFireTV/shared/androidx/media3/decoder/ffmpeg + jniLibs). DefaultRenderersFactory
# creates the renderer by reflection, and the native library calls back into the decoder (same as the TV app).
-keep class androidx.media3.decoder.ffmpeg.FfmpegAudioRenderer { <init>(...); }
-keepclasseswithmembernames class * {
    native <methods>;
}
-keep, includedescriptorclasses class androidx.media3.decoder.ffmpeg.FfmpegAudioDecoder {
  private java.nio.ByteBuffer growOutputBuffer(androidx.media3.decoder.SimpleDecoderOutputBuffer, int);
}
