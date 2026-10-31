package com.pritesh.nucflix.phone.ui

import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.pritesh.nucflix.phone.data.CloudAccount
import com.pritesh.nucflix.phone.data.CloudLine
import com.pritesh.nucflix.phone.data.PairedTv
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import java.text.DateFormat

/** A screen with a back arrow and a title. */
@Composable
fun SubScreen(title: String, onBack: (() -> Unit)?, action: @Composable () -> Unit = {}, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxSize().background(NucColors.Background).safeDrawingPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            if (onBack != null) IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            else Spacer(Modifier.size(16.dp))
            Text(title, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            action()
        }
        content()
    }
}

// ---------------------------------------------------------------- IPTV lines

/** The household's Xtream lines; tap one to watch through it, or edit it. */
@Composable
fun LinesScreen(cloud: CloudAccount, onBack: () -> Unit) {
    var editing by remember { mutableStateOf<CloudLine?>(null) }
    var adding by remember { mutableStateOf(false) }
    if (adding || editing != null) {
        LineFormScreen(cloud, editing, firstLine = false) { adding = false; editing = null }
        return
    }
    SubScreen("IPTV Lines", onBack, action = { IconButton(onClick = { cloud.error = null; adding = true }) { Icon(Icons.Filled.Add, "Add line") } }) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("Lines are shared by every profile and your TVs. The selected one is used on this phone.", color = NucColors.Muted, fontSize = 13.sp)
            cloud.lines.forEach { line ->
                val active = cloud.activeLine?.id == line.id
                Row(
                    Modifier.fillMaxWidth().background(NucColors.Surface, RoundedCornerShape(8.dp)).clickable { cloud.selectLine(line.id) }.padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(if (active) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked, null, tint = if (active) NucColors.Red else NucColors.Muted)
                    Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                        Text(line.name, fontWeight = FontWeight.SemiBold)
                        Text("${line.username} · ${Uri.parse(line.serverUrl).host ?: line.serverUrl}", color = NucColors.Muted, fontSize = 13.sp)
                    }
                    TextButton(onClick = { cloud.error = null; editing = line }) { Text("Edit") }
                }
            }
        }
    }
}

/** Add or edit a line. The login is checked with the provider before it's saved. */
@Composable
fun LineFormScreen(cloud: CloudAccount, line: CloudLine?, firstLine: Boolean, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(line?.name ?: "") }
    var server by remember { mutableStateOf(line?.serverUrl ?: "") }
    var username by remember { mutableStateOf(line?.username ?: "") }
    var password by remember { mutableStateOf(line?.password ?: "") }
    var showPassword by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    val ready = name.isNotBlank() && server.isNotBlank() && username.isNotBlank() && password.isNotEmpty()

    SubScreen(if (firstLine) "Add your IPTV line" else if (line == null) "Add Line" else "Edit Line", if (firstLine) null else onDone) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (firstLine) Text("Enter the Xtream Codes login from your IPTV provider. It's shared with your other devices.", color = NucColors.Muted, fontSize = 14.sp)
            OutlinedTextField(name, { name = it }, label = { Text("Name (e.g. Home)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(
                server, { server = it }, label = { Text("Server address") }, placeholder = { Text("panel.example.com:8080") },
                singleLine = true, modifier = Modifier.fillMaxWidth(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false)
            )
            OutlinedTextField(
                username, { username = it }, label = { Text("Username") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false)
            )
            OutlinedTextField(
                password, { password = it }, label = { Text("Password") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                trailingIcon = {
                    IconButton(onClick = { showPassword = !showPassword }) {
                        Icon(if (showPassword) Icons.Filled.VisibilityOff else Icons.Filled.Visibility, if (showPassword) "Hide" else "Show")
                    }
                }
            )
            cloud.error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 14.sp) }
            Button(
                onClick = { scope.launch { if (cloud.saveLine(line?.id, name, server, username, password) != null) onDone() } },
                enabled = ready && !cloud.busy,
                modifier = Modifier.fillMaxWidth().height(50.dp),
                colors = ButtonDefaults.buttonColors(containerColor = NucColors.Red)
            ) {
                if (cloud.busy) {
                    CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    Text("  Checking the login…")
                } else Text("Save Line", fontWeight = FontWeight.SemiBold)
            }
            if (firstLine) {
                TextButton(onClick = { cloud.signOut() }, modifier = Modifier.align(Alignment.CenterHorizontally)) {
                    Text("Sign out", color = NucColors.Muted)
                }
            }
            if (line != null) TextButton(onClick = { confirmDelete = true }) { Text("Delete Line", color = NucColors.Red) }
        }
    }
    if (confirmDelete && line != null) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete ${line.name}?") },
            text = { Text("Every profile and TV stops using this line.") },
            confirmButton = { TextButton(onClick = { confirmDelete = false; scope.launch { cloud.deleteLine(line); onDone() } }) { Text("Delete", color = NucColors.Red) } },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } }
        )
    }
}

// ---------------------------------------------------------------- Fire TV pairing

/** The code from a NucFlix pairing link (nucflix://pair?code=...), or null. */
fun pairCodeFrom(text: String?): String? {
    val uri = text?.let { runCatching { Uri.parse(it) }.getOrNull() } ?: return null
    if (uri.scheme != "nucflix" || uri.host != "pair") return null
    return uri.getQueryParameter("code")?.takeIf { it.isNotBlank() }
}

/** Pair a Fire TV by its code or QR code; lists the paired TVs so one can be removed. */
@Composable
fun PairTvScreen(cloud: CloudAccount, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var pairedName by remember { mutableStateOf<String?>(null) }
    var removing by remember { mutableStateOf<PairedTv?>(null) }
    LaunchedEffect(Unit) { cloud.error = null }

    fun pair(raw: String) {
        pairedName = null
        scope.launch { cloud.approvePairing(raw)?.let { pairedName = it; code = "" } }
    }

    SubScreen("Pair a TV", onBack) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(
                "On the TV, open NucFlix. It shows an 8-character code and a QR code. Enter the code here, or scan the QR code, " +
                    "to give the TV your profiles, IPTV lines, My List and Continue Watching.",
                color = NucColors.Muted, fontSize = 14.sp
            )
            // The typed text is never rewritten (doing so while typing dropped characters); it's normalised when
            // checked and submitted instead.
            val normalized = code.uppercase().filter { it.isLetterOrDigit() }
            OutlinedTextField(
                code, { code = it },
                placeholder = {
                    Text("K7Q2M9XD", Modifier.fillMaxWidth(), style = MaterialTheme.typography.headlineMedium.copy(
                        fontFamily = FontFamily.Monospace, textAlign = TextAlign.Center, letterSpacing = 6.sp, color = NucColors.Muted.copy(alpha = 0.5f)
                    ))
                },
                textStyle = MaterialTheme.typography.headlineMedium.copy(fontFamily = FontFamily.Monospace, textAlign = TextAlign.Center, letterSpacing = 6.sp),
                singleLine = true, modifier = Modifier.fillMaxWidth(),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false, imeAction = ImeAction.Go)
            )
            Button(
                onClick = { pair(normalized) }, enabled = normalized.length == 8 && !cloud.busy,
                modifier = Modifier.fillMaxWidth().height(50.dp), colors = ButtonDefaults.buttonColors(containerColor = NucColors.Red)
            ) { Text("Pair TV", fontWeight = FontWeight.SemiBold) }
            OutlinedButton(
                onClick = {
                    // Google's code scanner: no camera permission needed, the scan happens in Play services.
                    val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
                    scope.launch {
                        val scanned = runCatching { GmsBarcodeScanning.getClient(context, options).startScan().await().rawValue }.getOrNull()
                        val found = pairCodeFrom(scanned)
                        if (found != null) pair(found) else if (scanned != null) cloud.error = "That isn't a NucFlix pairing code."
                    }
                },
                enabled = !cloud.busy, modifier = Modifier.fillMaxWidth().height(50.dp)
            ) {
                Icon(Icons.Filled.QrCodeScanner, null)
                Text("  Scan the TV's QR code")
            }
            cloud.error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 14.sp) }
            pairedName?.let {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.CheckCircle, null, tint = NucColors.Green)
                    Text("  $it is paired. Pick a profile on the TV to start watching.", color = NucColors.Green)
                }
            }
            Text("Paired TVs", fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 12.dp))
            if (cloud.pairedTvs.isEmpty()) Text("No TVs yet", color = NucColors.Muted)
            cloud.pairedTvs.forEach { tv ->
                Row(
                    Modifier.fillMaxWidth().background(NucColors.Surface, RoundedCornerShape(8.dp)).padding(start = 14.dp, end = 4.dp, top = 6.dp, bottom = 6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(Icons.Filled.Tv, null, tint = Color.White)
                    Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                        Text(tv.name)
                        tv.pairedAt?.let { Text("Paired ${DateFormat.getDateInstance(DateFormat.MEDIUM).format(it)}", color = NucColors.Muted, fontSize = 12.sp) }
                    }
                    TextButton(onClick = { removing = tv }) { Text("Remove", color = NucColors.Red) }
                }
            }
        }
    }
    removing?.let { tv ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text("Remove ${tv.name}?") },
            text = { Text("It stops syncing with your account right away and shows a new pairing code.") },
            confirmButton = {
                TextButton(onClick = {
                    removing = null
                    if (pairedName == tv.name) pairedName = null
                    scope.launch { cloud.removeTv(tv) }
                }) { Text("Remove TV", color = NucColors.Red) }
            },
            dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel") } }
        )
    }
}
