package com.pritesh.nucflix.phone

import android.content.Intent
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.fragment.app.FragmentActivity
import com.pritesh.nucflix.phone.ui.NucFlixTheme
import com.pritesh.nucflix.phone.ui.Root
import com.pritesh.nucflix.phone.ui.pairCodeFrom

/** A FragmentActivity so the biometric prompt ("Forgot PIN?") can attach to it. */
class MainActivity : FragmentActivity() {
    private val cloud get() = (application as NucFlixApp).cloud

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        handle(intent)
        // Picks up downloads that were queued or running when the app last stopped.
        (application as NucFlixApp).downloads.resumeAll()
        setContent { NucFlixTheme { Root(cloud, (application as NucFlixApp).library) } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** nucflix://pair?code=... opened from a TV's QR code (camera, Lens, any scanner). */
    private fun handle(intent: Intent?) {
        pairCodeFrom(intent?.dataString)?.let { cloud.scannedPairCode = it }
    }
}
