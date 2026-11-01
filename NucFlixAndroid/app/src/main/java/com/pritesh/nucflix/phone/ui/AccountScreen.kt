package com.pritesh.nucflix.phone.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import com.pritesh.nucflix.phone.data.CloudAccount
import com.pritesh.nucflix.phone.data.Library

/** The profile's settings (synced with the TV and iPhone) and the household's lines and TVs. */
@Composable
fun AccountScreen(cloud: CloudAccount, library: Library, open: (Page) -> Unit, onBack: () -> Unit) {
    val activity = LocalContext.current as FragmentActivity
    val profile = cloud.selectedProfile ?: return
    SubScreen("Account", onBack) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ProfileAvatar(profile, 48.dp)
                Column(Modifier.padding(start = 12.dp)) {
                    Text(profile.name, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                    Text(cloud.email ?: "", color = NucColors.Muted, fontSize = 13.sp)
                }
            }
            Section("Playback")
            ToggleRow("Autoplay Next Episode", "Count down to the next episode when one ends", profile.autoplayNext) {
                cloud.savePrefs(profile, mapOf("autoplayNext" to it))
            }
            if (!profile.kids) {
                ToggleRow("Show Adult Content", "Turning this on asks for your phone's screen lock", profile.showAdult) { on ->
                    // Off right away; on only after the owner unlocks the phone (as the iPhone asks for Face ID).
                    if (!on) cloud.savePrefs(profile, mapOf("showAdult" to false))
                    else unlockWithDeviceOwner(activity, "Show adult content", "Confirm it's you to turn on adult content") {
                        cloud.savePrefs(profile, mapOf("showAdult" to true))
                    }
                }
            }
            Section("Household")
            NavRow(Icons.Filled.People, "Switch Profile", profile.name) { cloud.selectProfile(null) }
            NavRow(Icons.Filled.Dns, "IPTV Lines", library.line?.name ?: "") { cloud.error = null; open(Page.Lines) }
            NavRow(Icons.Filled.Tv, "Pair a TV", if (cloud.pairedTvs.isEmpty()) "No TVs yet" else "${cloud.pairedTvs.size} paired") { open(Page.PairTv) }
            NavRow(Icons.Filled.Download, "Downloads", "${(activity.application as com.pritesh.nucflix.phone.NucFlixApp).downloads.items.size} on this phone") { open(Page.Downloads) }
            NavRow(Icons.Filled.Refresh, "Refresh Catalog", "Reload titles from your provider") { library.load(force = true); onBack() }
            NavRow(Icons.AutoMirrored.Filled.Logout, "Sign Out", cloud.email ?: "") { library.stop(); cloud.signOut() }
        }
    }
}

@Composable
private fun Section(title: String) {
    Text(title.uppercase(), color = NucColors.Muted, fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp, modifier = Modifier.padding(top = 12.dp))
}

@Composable
private fun ToggleRow(title: String, subtitle: String, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().background(NucColors.Surface, RoundedCornerShape(8.dp)).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, fontWeight = FontWeight.Medium)
            Text(subtitle, color = NucColors.Muted, fontSize = 12.sp)
        }
        Switch(value, onChange, colors = SwitchDefaults.colors(checkedTrackColor = NucColors.Red))
    }
}

@Composable
private fun NavRow(icon: ImageVector, title: String, value: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().background(NucColors.Surface, RoundedCornerShape(8.dp)).clickable(onClick = onClick).padding(14.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = Color.White)
        Text(title, Modifier.weight(1f).padding(horizontal = 12.dp), fontWeight = FontWeight.Medium)
        Text(value, color = NucColors.Muted, fontSize = 13.sp)
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = NucColors.Muted)
    }
}
