package com.pritesh.nucflix.phone

import android.app.Application
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.FirebaseFirestoreSettings
import com.google.firebase.firestore.MemoryCacheSettings
import com.pritesh.nucflix.phone.data.CloudAccount

class NucFlixApp : Application() {
    lateinit var cloud: CloudAccount
        private set

    override fun onCreate() {
        super.onCreate()
        // Values from google-services.json, passed in by app/build.gradle.kts.
        val options = FirebaseOptions.Builder()
            .setApiKey(BuildConfig.FIREBASE_API_KEY)
            .setApplicationId(BuildConfig.FIREBASE_APP_ID)
            .setProjectId(BuildConfig.FIREBASE_PROJECT_ID)
            .setStorageBucket(BuildConfig.FIREBASE_STORAGE_BUCKET)
            .build()
        if (FirebaseApp.getApps(this).isEmpty()) FirebaseApp.initializeApp(this, options)
        val db = FirebaseFirestore.getInstance()
        // Memory-only cache, as on the iPhone: nothing from Firestore (Xtream logins included) is written to disk.
        db.firestoreSettings = FirebaseFirestoreSettings.Builder()
            .setLocalCacheSettings(MemoryCacheSettings.newBuilder().build())
            .build()
        if (BuildConfig.FIREBASE_EMULATOR) {
            // The host Mac, seen from the Android emulator.
            db.useEmulator("10.0.2.2", 8181)
            FirebaseAuth.getInstance().useEmulator("10.0.2.2", 9099)
        }
        cloud = CloudAccount(this)
    }
}
