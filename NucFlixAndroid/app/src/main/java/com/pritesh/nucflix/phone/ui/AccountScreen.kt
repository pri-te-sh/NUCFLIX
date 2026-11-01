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
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
import com.pritesh.nucflix.phone.data.XtreamClient
import java.text.DateFormat
import java.util.Date

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
            NavRow(Icons.Filled.QrCode, "Sign in another device", "") { open(Page.ApproveDevice) }
            NavRow(Icons.Filled.Download, "Downloads", "${(activity.application as com.pritesh.nucflix.phone.NucFlixApp).downloads.items.size} on this phone") { open(Page.Downloads) }
            library.client?.let { client ->
                Section("Subscription")
                SubscriptionPanel(library, client)
                Section("Catalog")
                CatalogPanel(library, client)
            }
            Section("App")
            NavRow(Icons.AutoMirrored.Filled.Logout, "Sign Out", cloud.email ?: "") { library.stop(); cloud.signOut() }
            Text("NucFlix for Android ${com.pritesh.nucflix.phone.BuildConfig.VERSION_NAME}", Modifier.fillMaxWidth().padding(top = 12.dp),
                color = NucColors.Muted, fontSize = 12.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
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

/** The line's subscription from the provider: status, time left, streams in use. */
@Composable
private fun SubscriptionPanel(library: Library, client: XtreamClient) {
    var info by remember(client) { mutableStateOf<XtreamClient.AccountInfo?>(null) }
    var failed by remember(client) { mutableStateOf(false) }
    LaunchedEffect(client) { info = client.accountInfo(); failed = info == null }
    Column(Modifier.fillMaxWidth().background(NucColors.Surface, RoundedCornerShape(8.dp))) {
        InfoRow("IPTV Line", library.line?.name ?: "—")
        val i = info
        when {
            i != null -> {
                InfoRow("Username", i.username.ifEmpty { library.line?.username ?: "—" })
                InfoRow("Status", listOf(i.status.replaceFirstChar { it.uppercase() } + if (i.trial) " (trial)" else "", timeLeft(i.expiresAt)).joinToString(" • "),
                    if (i.expiresAt != null && i.expiresAt * 1000 - System.currentTimeMillis() < 7 * 86_400_000L) NucColors.Red else Color.White)
                InfoRow("Expires", i.expiresAt?.let { DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(it * 1000)) } ?: "Never")
                InfoRow("Active Streams", "${i.activeConnections ?: 0} of ${i.maxConnections ?: 1} allowed")
                InfoRow("Server", i.server.removePrefix("https://").removePrefix("http://"), last = true)
            }
            failed -> InfoRow("Status", "Couldn't reach your provider", last = true)
            else -> Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.Center) {
                CircularProgressIndicator(Modifier.size(20.dp), color = NucColors.Red, strokeWidth = 2.dp)
            }
        }
    }
}

private fun timeLeft(expiresAt: Long?): String {
    expiresAt ?: return "Unlimited"
    val ms = expiresAt * 1000 - System.currentTimeMillis()
    val days = (ms / 86_400_000L).toInt()
    return when {
        ms <= 0 -> "Expired"
        days == 0 -> "Expires today"
        days == 1 -> "1 day left"
        days < 60 -> "$days days left"
        else -> "${days / 30} months left"
    }
}

/** What's indexed from the provider, when it was fetched, and a refresh. */
@Composable
private fun CatalogPanel(library: Library, client: XtreamClient) {
    @Suppress("UNUSED_VARIABLE") val rev = library.revision
    val cat = library.catalog
    val fmt = java.text.NumberFormat.getIntegerInstance()
    Column(Modifier.fillMaxWidth().background(NucColors.Surface, RoundedCornerShape(8.dp))) {
        InfoRow("Library", "${fmt.format(cat.movies.size)} movies • ${fmt.format(cat.series.size)} shows • ${fmt.format(cat.live.size)} channels")
        client.cachedAt().takeIf { it > 0 }?.let {
            InfoRow("Last Synced", DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(it)))
        }
        Row(Modifier.fillMaxWidth().clickable(enabled = !library.refreshing) { library.load(force = true) }.padding(14.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Refresh, null, tint = Color.White)
            Text(if (library.refreshing) "Refreshing Catalog…" else "Refresh Catalog Now", Modifier.weight(1f).padding(horizontal = 12.dp), fontWeight = FontWeight.Medium)
            if (library.refreshing) CircularProgressIndicator(Modifier.size(18.dp), color = Color.White, strokeWidth = 2.dp)
            else Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = NucColors.Muted)
        }
    }
}

@Composable
private fun InfoRow(label: String, value: String, valueColor: Color = Color.White, last: Boolean = false) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = NucColors.Muted, fontSize = 14.sp, modifier = Modifier.padding(end = 12.dp))
        Text(value, Modifier.weight(1f), color = valueColor, fontSize = 14.sp, textAlign = androidx.compose.ui.text.style.TextAlign.End, maxLines = 2)
    }
    if (!last) androidx.compose.material3.HorizontalDivider(Modifier.padding(start = 14.dp), color = Color.White.copy(alpha = 0.08f))
}
