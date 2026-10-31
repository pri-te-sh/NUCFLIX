import groovy.json.JsonSlurper

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Firebase settings come from google-services.json (read here instead of through the Google Services plugin).
@Suppress("UNCHECKED_CAST")
val firebase = (JsonSlurper().parse(file("google-services.json")) as Map<String, Any>).let { json ->
    val project = json["project_info"] as Map<String, Any>
    val client = (json["client"] as List<Map<String, Any>>).first()
    val apiKey = ((client["api_key"] as List<Map<String, Any>>).first())["current_key"] as String
    val appId = (client["client_info"] as Map<String, Any>)["mobilesdk_app_id"] as String
    val webClientId = (client["oauth_client"] as List<Map<String, Any>>).first { it["client_type"] == 3 }["client_id"] as String
    mapOf(
        "API_KEY" to apiKey, "APP_ID" to appId, "PROJECT_ID" to project["project_id"] as String,
        "STORAGE_BUCKET" to project["storage_bucket"] as String, "WEB_CLIENT_ID" to webClientId
    )
}

android {
    namespace = "com.pritesh.nucflix.phone"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.pritesh.nucflix.phone"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        firebase.forEach { (key, value) -> buildConfigField("String", "FIREBASE_$key", "\"$value\"") }
        // -Pnucflix.emulator=true points a build at the local Firebase emulators (testing only).
        buildConfigField("boolean", "FIREBASE_EMULATOR", (project.findProperty("nucflix.emulator") as String?).toBoolean().toString())
    }

    buildTypes {
        release {
            // Shrunk and optimised: Compose in a debug build is interpreted and far slower than what users get.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Signed with the debug key until a release key is set up (sideloading and testing).
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // The player pieces shared with the Fire TV app, compiled from its folder so fixes reach both apps: FFmpeg
    // audio decoders (DTS, TrueHD...), the MKV repair extractor and the live-TS timestamp re-baser.
    sourceSets["main"].java.srcDir("../../NucFlixFireTV/shared")
    sourceSets["main"].jniLibs.srcDir("../../NucFlixFireTV/jniLibs")
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.core:core-ktx:1.19.1")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.fragment:fragment-ktx:1.9.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.11.0")
    implementation("androidx.biometric:biometric:1.1.0")

    implementation(platform("com.google.firebase:firebase-bom:35.1.0"))
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.firebase:firebase-firestore")
    implementation("com.google.firebase:firebase-functions")

    // 1.10.1: the version the shared FFmpeg library and MKV extractor were built against.
    implementation("androidx.media3:media3-exoplayer:1.10.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.10.1")
    implementation("androidx.media3:media3-ui:1.10.1")
    implementation("io.coil-kt.coil3:coil-compose:3.6.3")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.6.3")

    implementation("androidx.credentials:credentials:1.6.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.6.0")
    implementation("com.google.android.libraries.identity.googleid:googleid:1.2.1")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.11.0")
}
