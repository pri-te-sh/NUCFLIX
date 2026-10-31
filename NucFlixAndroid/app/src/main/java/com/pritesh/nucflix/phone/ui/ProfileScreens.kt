package com.pritesh.nucflix.phone.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.fragment.app.FragmentActivity
import com.pritesh.nucflix.phone.data.CloudAccount
import com.pritesh.nucflix.phone.data.CloudProfile
import kotlinx.coroutines.launch

const val MAX_PROFILES = 10

/** The profile editor's subject: an existing profile, or null for a new one. */
private data class EditorTarget(val profile: CloudProfile?)

/** What a PIN unlocks: opening or editing a locked profile, or adding one while others are locked. */
private sealed interface PinTarget {
    data class Open(val profile: CloudProfile) : PinTarget
    data class Edit(val profile: CloudProfile) : PinTarget
    data object Add : PinTarget
}

/** "Who's watching?": the household's profiles (synced with the iPhone and the TVs). */
@Composable
fun ProfilePickerScreen(cloud: CloudAccount) {
    val activity = LocalContext.current as FragmentActivity
    var editing by remember { mutableStateOf(false) }
    var editorFor by remember { mutableStateOf<EditorTarget?>(null) }
    var pinTarget by remember { mutableStateOf<PinTarget?>(null) }

    fun unlocked(target: PinTarget) {
        pinTarget = null
        when (target) {
            is PinTarget.Open -> cloud.selectProfile(target.profile.id)
            is PinTarget.Edit -> editorFor = EditorTarget(target.profile)
            PinTarget.Add -> editorFor = EditorTarget(null)
        }
    }

    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Wordmark(size = 26)
            Spacer(Modifier.weight(1f))
            if (cloud.profiles.isNotEmpty()) {
                TextButton(onClick = { editing = !editing }) {
                    Text(if (editing) "Done" else "Edit", color = Color.White, fontWeight = FontWeight.SemiBold)
                }
            }
        }
        Text(
            if (editing) "Manage Profiles" else "Who's watching?",
            fontSize = 26.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.align(Alignment.CenterHorizontally).padding(top = 32.dp, bottom = 28.dp)
        )
        LazyVerticalGrid(
            columns = GridCells.Adaptive(118.dp),
            modifier = Modifier.weight(1f).padding(horizontal = 24.dp),
            horizontalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterHorizontally),
            verticalArrangement = Arrangement.spacedBy(26.dp)
        ) {
            items(cloud.profiles, key = { it.id }) { profile ->
                ProfileTile(profile, editing) {
                    when {
                        profile.isLocked -> pinTarget = if (editing) PinTarget.Edit(profile) else PinTarget.Open(profile)
                        editing -> editorFor = EditorTarget(profile)
                        else -> cloud.selectProfile(profile.id)
                    }
                }
            }
            if (cloud.profiles.size < MAX_PROFILES) {
                item {
                    Column(
                        Modifier.clickable {
                            // With locked profiles, adding one needs one of their PINs (else it's a way around them).
                            if (cloud.profiles.any { it.isLocked }) pinTarget = PinTarget.Add else editorFor = EditorTarget(null)
                        },
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Box(
                            Modifier.size(104.dp).border(2.dp, Color.White.copy(alpha = 0.45f), RoundedCornerShape(10.dp)),
                            contentAlignment = Alignment.Center
                        ) { Icon(Icons.Filled.Add, null, tint = Color.White.copy(alpha = 0.8f), modifier = Modifier.size(40.dp)) }
                        Text("Add Profile", color = Color.White.copy(alpha = 0.7f), fontSize = 14.sp, modifier = Modifier.padding(top = 10.dp))
                    }
                }
            }
        }
        cloud.email?.let { email ->
            Column(Modifier.fillMaxWidth().padding(bottom = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(email, color = Color.White.copy(alpha = 0.45f), fontSize = 13.sp)
                TextButton(onClick = { cloud.signOut() }) { Text("Sign out of NucFlix", color = Color.White.copy(alpha = 0.7f), fontSize = 13.sp) }
            }
        }
    }

    pinTarget?.let { target ->
        val locked = when (target) {
            is PinTarget.Open -> listOf(target.profile)
            is PinTarget.Edit -> listOf(target.profile)
            PinTarget.Add -> cloud.profiles.filter { it.isLocked }
        }
        PinPadDialog(
            title = when (target) {
                is PinTarget.Open -> "Enter ${target.profile.name}'s PIN"
                is PinTarget.Edit -> "Enter ${target.profile.name}'s PIN"
                PinTarget.Add -> "Enter a profile PIN"
            },
            subtitle = if (target == PinTarget.Add) "Adding a profile needs the PIN of ${locked.joinToString(" or ") { it.name }}." else null,
            onForgot = { unlockWithDeviceOwner(activity) { unlocked(target) } },
            onDismiss = { pinTarget = null }
        ) { pin ->
            if (locked.any { it.pinMatches(pin) }) {
                unlocked(target)
                PinResult.Done
            } else PinResult.Wrong
        }
    }

    editorFor?.let { ProfileEditorDialog(cloud, it.profile) { editorFor = null } }
}

@Composable
private fun ProfileTile(profile: CloudProfile, editing: Boolean, onClick: () -> Unit) {
    Column(Modifier.clickable(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally) {
        Box {
            ProfileAvatar(profile, 104.dp)
            if (profile.isLocked) {
                Box(
                    Modifier.align(Alignment.TopEnd).padding(6.dp).size(26.dp).background(Color.Black.copy(alpha = 0.55f), CircleShape),
                    contentAlignment = Alignment.Center
                ) { Icon(Icons.Filled.Lock, "Locked", tint = Color.White, modifier = Modifier.size(15.dp)) }
            }
            if (editing) {
                Box(
                    Modifier.size(104.dp).clip(RoundedCornerShape(10.dp)).background(Color.Black.copy(alpha = 0.5f)),
                    contentAlignment = Alignment.Center
                ) { Icon(Icons.Filled.Edit, "Edit", tint = Color.White, modifier = Modifier.size(32.dp)) }
            }
        }
        Text(
            profile.name, fontSize = 14.sp, color = Color.White.copy(alpha = 0.85f), maxLines = 1,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 10.dp).width(110.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center
        )
    }
}

/** Add or edit a profile: name, colour, kids, Profile Lock, delete. */
@Composable
fun ProfileEditorDialog(cloud: CloudAccount, profile: CloudProfile?, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(profile?.name ?: "") }
    var avatar by remember {
        mutableStateOf(profile?.avatar ?: CloudProfile.avatarColors.firstOrNull { c -> cloud.profiles.none { it.avatar == c } } ?: "red")
    }
    var kids by remember { mutableStateOf(profile?.kids ?: false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var choosingPin by remember { mutableStateOf(false) }
    // The live profile: the lock can change while the editor is open.
    val live = cloud.profiles.firstOrNull { it.id == profile?.id }
    val lockedNow = live?.isLocked == true
    val trimmed = name.trim().take(40)
    val preview = CloudProfile("preview", trimmed.ifEmpty { "?" }, avatar, kids, 0, true, false, "")

    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(NucColors.Background).safeDrawingPadding()) {
            Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onClose) { Text("Cancel", color = Color.White) }
                Text(if (profile == null) "Add Profile" else "Edit Profile", Modifier.weight(1f), fontWeight = FontWeight.SemiBold,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                TextButton(
                    onClick = { scope.launch { if (cloud.saveProfile(profile?.id, trimmed, avatar, kids) != null) onClose() } },
                    enabled = trimmed.isNotEmpty() && !cloud.busy
                ) { Text("Save", fontWeight = FontWeight.SemiBold) }
            }
            Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                ProfileAvatar(preview, 96.dp, Modifier.align(Alignment.CenterHorizontally).padding(top = 8.dp))
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Text("Colour", color = NucColors.Muted, fontSize = 13.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    CloudProfile.avatarColors.forEach { key ->
                        Box(
                            Modifier.size(34.dp).clip(CircleShape).background(NucColors.avatar(key))
                                .border(if (avatar == key) 3.dp else 0.dp, Color.White, CircleShape)
                                .clickable { avatar = key }
                        )
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Kids profile")
                        Text("Only titles suitable for children, and never adult content.", color = NucColors.Muted, fontSize = 13.sp)
                    }
                    Switch(kids, { kids = it }, colors = SwitchDefaults.colors(checkedTrackColor = NucColors.Red))
                }
                if (profile != null && !kids) {
                    HorizontalDivider(color = NucColors.SurfaceHigh)
                    Text("Profile Lock", fontWeight = FontWeight.SemiBold)
                    Text(
                        if (lockedNow) "A 4-digit PIN is needed to open or edit this profile on every device."
                        else "Ask for a 4-digit PIN to open this profile on your phones and TVs.",
                        color = NucColors.Muted, fontSize = 13.sp
                    )
                    if (lockedNow) {
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Button(onClick = { choosingPin = true }, colors = ButtonDefaults.buttonColors(containerColor = NucColors.SurfaceHigh)) { Text("Change PIN") }
                            TextButton(onClick = { live?.let { scope.launch { cloud.setProfilePin(it, "") } } }) { Text("Turn Off Lock", color = NucColors.Red) }
                        }
                    } else {
                        Button(onClick = { choosingPin = true }, colors = ButtonDefaults.buttonColors(containerColor = NucColors.SurfaceHigh)) { Text("Turn On Profile Lock") }
                    }
                }
                cloud.error?.let { Text(it, color = androidx.compose.material3.MaterialTheme.colorScheme.error, fontSize = 14.sp) }
                if (profile != null) {
                    HorizontalDivider(color = NucColors.SurfaceHigh)
                    TextButton(onClick = { confirmDelete = true }) { Text("Delete Profile", color = NucColors.Red) }
                    Text("Removes this profile's My List and Continue Watching on all devices.", color = NucColors.Muted, fontSize = 13.sp)
                }
                Spacer(Modifier.height(24.dp))
            }
        }
    }

    if (choosingPin && profile != null) {
        PinChooserDialog(onDismiss = { choosingPin = false }) { pin ->
            scope.launch { cloud.setProfilePin(profile, CloudProfile.pinHash(profile.id, pin)) }
        }
    }
    if (confirmDelete && profile != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete ${profile.name}?") },
            text = { Text("Their My List and Continue Watching are removed on every device.") },
            confirmButton = {
                TextButton(onClick = { confirmDelete = false; scope.launch { cloud.deleteProfile(profile); onClose() } }) {
                    Text("Delete Profile", color = NucColors.Red)
                }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } }
        )
    }
}
