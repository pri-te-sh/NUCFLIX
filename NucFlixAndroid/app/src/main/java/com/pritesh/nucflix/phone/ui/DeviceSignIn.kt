package com.pritesh.nucflix.phone.ui

import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.PhoneIphone
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.firebase.FirebaseNetworkException
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.functions.FirebaseFunctions
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.pritesh.nucflix.phone.data.CloudAccount
import com.pritesh.nucflix.phone.data.CloudError
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await

/** The code from a "sign in with another device" link (nucflix://signin?code=...), or null. */
fun signInCodeFrom(text: String?): String? {
    val uri = text?.let { runCatching { Uri.parse(it) }.getOrNull() } ?: return null
    if (uri.scheme != "nucflix" || uri.host != "signin") return null
    return uri.getQueryParameter("code")?.takeIf { it.isNotBlank() }
}

// ---------------------------------------------------------------- the new phone

/**
 * "Sign in with another device" on the phone being signed in: it gets a code from the deviceSignIn Cloud Function
 * (signed in anonymously just for that), shows it as text and a QR code, and waits for a phone that's signed in to
 * approve it. The approval arrives on deviceSignIn/{code}; the code is then swapped for a sign-in token.
 */
private class DeviceSignInSession(private val scope: CoroutineScope, private val deviceName: String) {
    sealed interface State {
        data object Starting : State
        data class Waiting(val code: String, val expiresAt: Long) : State
        data object SigningIn : State
        data class Failed(val message: String) : State
    }

    var state by mutableStateOf<State>(State.Starting); private set

    private val auth = FirebaseAuth.getInstance()
    private val callable get() = FirebaseFunctions.getInstance("us-central1").getHttpsCallable("deviceSignIn")
    private var listener: ListenerRegistration? = null

    suspend fun start() {
        stopWaiting()
        state = State.Starting
        try {
            if (auth.currentUser?.isAnonymous != true) auth.signInAnonymously().await()
            val data = callable.call(mapOf("action" to "start", "name" to deviceName, "platform" to "android")).await().getData() as? Map<*, *>
            val code = data?.get("code") as? String
            val expiresAt = (data?.get("expiresAt") as? Number)?.toLong()
            if (code == null || expiresAt == null) throw CloudError("Couldn't get a code. Try again.")
            state = State.Waiting(code, expiresAt)
            listener = FirebaseFirestore.getInstance().collection("deviceSignIn").document(code).addSnapshotListener { snap, _ ->
                if (snap?.getString("status") == "approved") scope.launch { redeem(code) }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            state = State.Failed(describe(e))
        }
    }

    private suspend fun redeem(code: String) {
        if ((state as? State.Waiting)?.code != code) return
        stopWaiting()
        state = State.SigningIn
        try {
            val data = callable.call(mapOf("action" to "redeem", "code" to code)).await().getData() as? Map<*, *>
            val token = data?.get("token") as? String ?: throw CloudError("The approval didn't come through. Try again.")
            // CloudAccount picks the account up from here, like any other sign-in.
            auth.signInWithCustomToken(token).await()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            state = State.Failed(describe(e))
        }
    }

    /** Stops waiting; the anonymous user only existed to ask for the code, so it goes too. */
    fun cancel() {
        stopWaiting()
        auth.currentUser?.takeIf { it.isAnonymous }?.delete()
    }

    private fun stopWaiting() {
        listener?.remove()
        listener = null
    }

    private fun describe(e: Exception) = when (e) {
        is FirebaseNetworkException, is java.io.IOException -> "No connection. Check your internet and try again."
        else -> e.message ?: "Something went wrong."
    }
}

@Composable
fun DeviceSignInScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val session = remember {
        val name = Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() } ?: Build.MODEL
        DeviceSignInSession(scope, name)
    }
    LaunchedEffect(Unit) { session.start() }
    DisposableEffect(Unit) { onDispose { if (session.state != DeviceSignInSession.State.SigningIn) session.cancel() } }

    SubScreen("Sign in with another device", onBack) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp)
        ) {
            Text(
                "On a phone or tablet that's already signed in to NucFlix, open Account, then Sign in another device, " +
                    "and enter this code, or scan the QR code with its camera.",
                color = NucColors.Muted, fontSize = 15.sp, textAlign = TextAlign.Center
            )
            when (val state = session.state) {
                DeviceSignInSession.State.Starting -> Box(Modifier.height(300.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = NucColors.Red)
                }
                is DeviceSignInSession.State.Waiting -> {
                    // An unused code expires: show a fresh one.
                    var left by remember(state.code) { mutableLongStateOf(state.expiresAt - System.currentTimeMillis()) }
                    LaunchedEffect(state.code) {
                        while (left > 0) {
                            delay(1000)
                            left = state.expiresAt - System.currentTimeMillis()
                        }
                        session.start()
                    }
                    Text(state.code, fontFamily = FontFamily.Monospace, fontSize = 36.sp, fontWeight = FontWeight.Bold, letterSpacing = 6.sp)
                    val qr = remember(state.code) { qrCode("nucflix://signin?code=${state.code}") }
                    Box(Modifier.background(Color.White, RoundedCornerShape(14.dp)).padding(14.dp)) {
                        Image(qr, "QR code for ${state.code}", Modifier.size(200.dp), filterQuality = FilterQuality.None)
                    }
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        CircularProgressIndicator(Modifier.size(16.dp), color = NucColors.Muted, strokeWidth = 2.dp)
                        Text("Waiting for approval", color = NucColors.Muted)
                    }
                    val seconds = (left / 1000).coerceAtLeast(0)
                    Text("New code in %d:%02d".format(seconds / 60, seconds % 60), color = NucColors.Muted.copy(alpha = 0.7f), fontSize = 13.sp)
                    TextButton(onClick = { scope.launch { session.start() } }) { Text("Get a new code", color = Color.White) }
                }
                DeviceSignInSession.State.SigningIn -> Column(
                    Modifier.height(300.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center
                ) {
                    CircularProgressIndicator(color = NucColors.Red)
                    Text("Approved. Signing in…", Modifier.padding(top = 14.dp), fontWeight = FontWeight.SemiBold)
                }
                is DeviceSignInSession.State.Failed -> {
                    Text(state.message, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center)
                    Button(onClick = { scope.launch { session.start() } }, colors = ButtonDefaults.buttonColors(containerColor = NucColors.Red)) {
                        Text("Try again")
                    }
                }
            }
        }
    }
}

private fun qrCode(text: String): ImageBitmap {
    val hints = mapOf(EncodeHintType.MARGIN to 0, EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M)
    val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0, hints)
    val pixels = IntArray(matrix.width * matrix.height) { i ->
        if (matrix[i % matrix.width, i / matrix.width]) android.graphics.Color.BLACK else android.graphics.Color.WHITE
    }
    return Bitmap.createBitmap(pixels, matrix.width, matrix.height, Bitmap.Config.ARGB_8888).asImageBitmap()
}

// ---------------------------------------------------------------- the phone that's signed in

/**
 * Lets another phone or tablet into this account: enter or scan the code it shows (a scanned QR code opens this with
 * the code filled in), check which device it is, then approve.
 */
@Composable
fun ApproveDeviceScreen(cloud: CloudAccount, initialCode: String?, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf(initialCode.orEmpty()) }
    var device by remember { mutableStateOf<CloudAccount.WaitingDevice?>(null) }
    var approved by remember { mutableStateOf<CloudAccount.WaitingDevice?>(null) }
    // The typed text is never rewritten (doing so while typing dropped characters); it's normalised when used.
    val normalized = code.uppercase().filter { it.isLetterOrDigit() }

    fun lookUp(raw: String) {
        if (raw.length != 8) return
        scope.launch { device = cloud.lookUpDeviceSignIn(raw) }
    }
    LaunchedEffect(Unit) {
        cloud.error = null
        if (initialCode != null) lookUp(normalized)
    }

    SubScreen("Sign in another device", onBack) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            val waiting = device
            val done = approved
            when {
                done != null -> Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.CheckCircle, null, tint = NucColors.Green)
                    Text("  ${done.name} is signed in to your account.", color = NucColors.Green)
                }
                waiting != null -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(if (waiting.platform == "ios") Icons.Filled.PhoneIphone else Icons.Filled.PhoneAndroid, null, tint = Color.White)
                        Text("  Sign in ${waiting.name}?", fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                    }
                    Text(
                        "It gets this whole account, like this phone: every profile, your IPTV lines, My List and Continue " +
                            "Watching. Only approve a device you have with you.",
                        color = NucColors.Muted, fontSize = 14.sp
                    )
                    Button(
                        onClick = {
                            scope.launch {
                                cloud.approveDeviceSignIn(normalized)?.let { approved = it; device = null; code = "" }
                            }
                        },
                        enabled = !cloud.busy, modifier = Modifier.fillMaxWidth().height(50.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = NucColors.Red)
                    ) {
                        if (cloud.busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        else Text("Approve", fontWeight = FontWeight.SemiBold)
                    }
                    TextButton(onClick = onBack, modifier = Modifier.fillMaxWidth()) { Text("Not now", color = Color.White) }
                }
                else -> {
                    Text(
                        "On the phone or tablet you want to sign in, open NucFlix and choose Sign in with another device. " +
                            "Enter the code it shows, or scan its QR code.",
                        color = NucColors.Muted, fontSize = 14.sp
                    )
                    OutlinedTextField(
                        code, { code = it },
                        placeholder = {
                            Text("K7Q2M9XD", Modifier.fillMaxWidth(), style = MaterialTheme.typography.headlineMedium.copy(
                                fontFamily = FontFamily.Monospace, textAlign = TextAlign.Center, letterSpacing = 6.sp, color = NucColors.Muted.copy(alpha = 0.5f)
                            ))
                        },
                        textStyle = MaterialTheme.typography.headlineMedium.copy(fontFamily = FontFamily.Monospace, textAlign = TextAlign.Center, letterSpacing = 6.sp),
                        singleLine = true, modifier = Modifier.fillMaxWidth(),
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false, imeAction = ImeAction.Go),
                        keyboardActions = KeyboardActions(onGo = { lookUp(normalized) })
                    )
                    Button(
                        onClick = { lookUp(normalized) }, enabled = normalized.length == 8 && !cloud.busy,
                        modifier = Modifier.fillMaxWidth().height(50.dp), colors = ButtonDefaults.buttonColors(containerColor = NucColors.Red)
                    ) {
                        if (cloud.busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        else Text("Continue", fontWeight = FontWeight.SemiBold)
                    }
                    OutlinedButton(
                        onClick = {
                            // Google's code scanner: no camera permission needed, the scan happens in Play services.
                            val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
                            scope.launch {
                                val scanned = runCatching { GmsBarcodeScanning.getClient(context, options).startScan().await().rawValue }.getOrNull()
                                val found = signInCodeFrom(scanned)
                                if (found != null) {
                                    code = found
                                    lookUp(found.uppercase().filter { it.isLetterOrDigit() })
                                } else if (scanned != null) {
                                    cloud.error = "That isn't a NucFlix sign-in code."
                                }
                            }
                        },
                        enabled = !cloud.busy, modifier = Modifier.fillMaxWidth().height(50.dp)
                    ) {
                        Icon(Icons.Filled.QrCodeScanner, null)
                        Text("  Scan the QR code")
                    }
                }
            }
            cloud.error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 14.sp) }
        }
    }
}
