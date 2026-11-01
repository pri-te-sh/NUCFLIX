package com.pritesh.nucflix.phone.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.pritesh.nucflix.phone.data.CloudAccount
import com.pritesh.nucflix.phone.data.Library
import androidx.compose.runtime.LaunchedEffect
import kotlinx.coroutines.launch

/** Which screen the account state calls for (the same steps as the iPhone app). */
@Composable
fun Root(cloud: CloudAccount, library: Library) {
    Box(Modifier.fillMaxSize().background(NucColors.Background)) {
        when {
            cloud.phase == CloudAccount.Phase.STARTING -> Loading()
            cloud.phase == CloudAccount.Phase.SIGNED_OUT -> AuthScreen(cloud)
            !cloud.profilesLoaded || !cloud.linesLoaded -> Loading()
            cloud.selectedProfile == null -> ProfilePickerScreen(cloud)
            cloud.activeLine == null -> LineFormScreen(cloud, null, firstLine = true) {}
            else -> {
                val uid = cloud.uid
                val profile = cloud.selectedProfile
                val line = cloud.activeLine
                // Starts (or keeps) the catalog and sync for this profile + line; profile prefs changes refilter.
                LaunchedEffect(uid, profile, line) { if (uid != null && profile != null && line != null) library.activate(uid, profile, line) }
                MainScreen(cloud, library)
            }
        }
    }
    ScannedPairPrompt(cloud)
    // Another phone's "sign in with another device" QR code (nucflix://signin?code=...): shows which device it is
    // before anything is approved.
    val signInCode = cloud.scannedSignInCode
    if (signInCode != null && cloud.phase == CloudAccount.Phase.SIGNED_IN) {
        Dialog({ cloud.scannedSignInCode = null }, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
            ApproveDeviceScreen(cloud, signInCode) { cloud.scannedSignInCode = null }
        }
    }
}

@Composable
private fun Loading() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = NucColors.Red) }
}

/**
 * A scanned TV QR code (nucflix://pair?code=...): one tap to confirm, so a stray QR code can't add a TV to the
 * account (a paired TV can read the IPTV logins). Waits until the user is signed in.
 */
@Composable
private fun ScannedPairPrompt(cloud: CloudAccount) {
    val scope = rememberCoroutineScope()
    var result by remember { mutableStateOf<String?>(null) }
    val code = cloud.scannedPairCode
    if (code != null && cloud.phase == CloudAccount.Phase.SIGNED_IN) {
        AlertDialog(
            onDismissRequest = { cloud.scannedPairCode = null },
            title = { Text("Pair this TV?") },
            text = { Text("The TV showing code $code will get your profiles, IPTV lines, My List and Continue Watching.") },
            confirmButton = {
                TextButton(onClick = {
                    cloud.scannedPairCode = null
                    scope.launch {
                        val name = cloud.approvePairing(code)
                        result = if (name != null) "$name is paired. Pick a profile on the TV to start watching." else cloud.error ?: "Couldn't pair the TV."
                    }
                }) { Text("Pair") }
            },
            dismissButton = { TextButton(onClick = { cloud.scannedPairCode = null }) { Text("Cancel") } }
        )
    }
    result?.let {
        AlertDialog(
            onDismissRequest = { result = null },
            title = { Text("Pair a TV") },
            text = { Text(it) },
            confirmButton = { TextButton(onClick = { result = null }) { Text("OK") } }
        )
    }
}
