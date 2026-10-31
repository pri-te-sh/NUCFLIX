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
import com.pritesh.nucflix.phone.data.CloudAccount
import kotlinx.coroutines.launch

/** Which screen the account state calls for (the same steps as the iPhone app). */
@Composable
fun Root(cloud: CloudAccount) {
    Box(Modifier.fillMaxSize().background(NucColors.Background)) {
        when {
            cloud.phase == CloudAccount.Phase.STARTING -> Loading()
            cloud.phase == CloudAccount.Phase.SIGNED_OUT -> AuthScreen(cloud)
            !cloud.profilesLoaded || !cloud.linesLoaded -> Loading()
            cloud.selectedProfile == null -> ProfilePickerScreen(cloud)
            cloud.activeLine == null -> LineFormScreen(cloud, null, firstLine = true) {}
            else -> HomeScreen(cloud)
        }
    }
    ScannedPairPrompt(cloud)
}

@Composable
private fun Loading() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = NucColors.Red) }
}

private enum class Page { HOME, LINES, PAIR }

/** Stage 1 home: who's watching and the household settings. Browsing and playback come in stage 2. */
@Composable
private fun HomeScreen(cloud: CloudAccount) {
    var page by remember { mutableStateOf(Page.HOME) }
    BackHandler(page != Page.HOME) { page = Page.HOME }
    when (page) {
        Page.LINES -> { LinesScreen(cloud) { page = Page.HOME }; return }
        Page.PAIR -> { PairTvScreen(cloud) { page = Page.HOME }; return }
        Page.HOME -> Unit
    }
    val profile = cloud.selectedProfile ?: return
    Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState())) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Wordmark(size = 26)
            Spacer(Modifier.weight(1f))
            ProfileAvatar(profile, 34.dp, Modifier.clickable { cloud.selectProfile(null) })
        }
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Hi ${profile.name}", fontSize = 28.sp, fontWeight = FontWeight.Bold)
            Text(
                "Watching through ${cloud.activeLine?.name ?: "your line"}. Browsing and playback arrive in the next update; " +
                    "your account, profiles, lines and TVs are ready.",
                color = NucColors.Muted, fontSize = 15.sp
            )
            Spacer(Modifier.size(8.dp))
            MenuRow(Icons.Filled.People, "Switch Profile", profile.name) { cloud.selectProfile(null) }
            MenuRow(Icons.Filled.Dns, "IPTV Lines", "${cloud.lines.size} in your account") { cloud.error = null; page = Page.LINES }
            MenuRow(Icons.Filled.Tv, "Pair a TV", if (cloud.pairedTvs.isEmpty()) "No TVs yet" else "${cloud.pairedTvs.size} paired") { page = Page.PAIR }
            MenuRow(Icons.AutoMirrored.Filled.Logout, "Sign Out", cloud.email ?: "") { cloud.signOut() }
        }
    }
}

@Composable
private fun MenuRow(icon: ImageVector, title: String, value: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().background(NucColors.Surface, RoundedCornerShape(8.dp)).clickable(onClick = onClick).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, null, tint = Color.White)
        Text(title, Modifier.weight(1f).padding(horizontal = 14.dp), fontWeight = FontWeight.Medium)
        Text(value, color = NucColors.Muted, fontSize = 13.sp)
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = NucColors.Muted)
    }
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
