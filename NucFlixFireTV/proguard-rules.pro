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
