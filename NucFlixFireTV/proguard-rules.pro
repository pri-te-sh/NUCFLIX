# NucFlix R8 rules (library consumer rules come from libs/*.pro).
-dontobfuscate
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod,SourceFile,LineNumberTable
-keepclassmembers class * { @android.webkit.JavascriptInterface <methods>; }
-keep class com.pritesh.nucflix.** { *; }
-dontwarn org.checkerframework.**
-dontwarn com.google.errorprone.**
-dontwarn com.google.j2objc.**
-dontwarn javax.annotation.**
-dontwarn kotlin.**
-dontwarn org.jetbrains.annotations.**
-dontwarn com.google.common.**
# Media3 references newer platform APIs behind SDK_INT checks; they're absent from the API 33 android.jar.
-dontwarn android.media.**
-dontwarn android.os.**
-dontwarn android.view.**
-dontwarn android.hardware.**
-dontwarn android.window.**

# FFmpeg audio decoder (src/androidx/media3/decoder/ffmpeg, jniLibs). DefaultRenderersFactory creates the
# renderer by reflection, and the native library calls back into the decoder.
-keep class androidx.media3.decoder.ffmpeg.FfmpegAudioRenderer { <init>(...); }
-keepclasseswithmembernames class * {
    native <methods>;
}
-keep, includedescriptorclasses class androidx.media3.decoder.ffmpeg.FfmpegAudioDecoder {
  private java.nio.ByteBuffer growOutputBuffer(androidx.media3.decoder.SimpleDecoderOutputBuffer, int);
}
