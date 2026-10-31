package com.pritesh.nucflix.phone.ui

import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_WEAK
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.keyframes
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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Backspace
import androidx.compose.material.icons.filled.Lock
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.launch

sealed interface PinResult {
    /** Correct: the pad closes. */
    data object Done : PinResult
    /** Wrong PIN: shake and clear. */
    data object Wrong : PinResult
    /** The next step ("Enter the same PIN again"): clear and show it. */
    data class Message(val text: String) : PinResult
}

/** A full-screen 4-digit PIN keypad. */
@Composable
fun PinPadDialog(
    title: String,
    subtitle: String? = null,
    onForgot: (() -> Unit)? = null,
    onDismiss: () -> Unit,
    onPin: (String) -> PinResult
) {
    var pin by remember { mutableStateOf("") }
    var message by remember { mutableStateOf("") }
    var wrong by remember { mutableStateOf(false) }
    val shake = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()

    fun press(digit: Char) {
        if (pin.length >= 4) return
        pin += digit
        message = ""
        if (pin.length < 4) return
        val entered = pin
        pin = ""
        when (val r = onPin(entered)) {
            PinResult.Done -> onDismiss()
            PinResult.Wrong -> {
                message = "Wrong PIN. Try again."
                wrong = true
                scope.launch {
                    shake.animateTo(0f, keyframes { durationMillis = 400; -14f at 80; 14f at 160; -14f at 240; 14f at 320 })
                }
            }
            is PinResult.Message -> { message = r.text; wrong = false }
        }
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier
                .fillMaxSize()
                .background(Color.Black)
                .safeDrawingPadding()
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onDismiss) { Text("Cancel", color = Color.White) }
            }
            Spacer(Modifier.weight(1f))
            Icon(Icons.Filled.Lock, null, tint = Color.White.copy(alpha = 0.8f), modifier = Modifier.size(30.dp))
            Spacer(Modifier.height(16.dp))
            Text(title, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
            subtitle?.let {
                Spacer(Modifier.height(6.dp))
                Text(it, color = NucColors.Muted, fontSize = 14.sp, textAlign = TextAlign.Center)
            }
            Spacer(Modifier.height(26.dp))
            Row(Modifier.offset { IntOffset(shake.value.dp.roundToPx(), 0) }, horizontalArrangement = Arrangement.spacedBy(22.dp)) {
                repeat(4) { i ->
                    Box(
                        Modifier
                            .size(18.dp)
                            .border(2.dp, Color.White.copy(alpha = 0.7f), CircleShape)
                            .background(if (i < pin.length) Color.White else Color.Transparent, CircleShape)
                    )
                }
            }
            Text(message, color = if (wrong) NucColors.Red else NucColors.Muted, fontSize = 13.sp, modifier = Modifier.padding(top = 14.dp).height(20.dp))
            Spacer(Modifier.height(10.dp))
            val rows = listOf("123", "456", "789")
            rows.forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(22.dp), modifier = Modifier.padding(bottom = 18.dp)) {
                    row.forEach { d -> PinKey(d.toString()) { press(d) } }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(22.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(72.dp), contentAlignment = Alignment.Center) {
                    if (onForgot != null) TextButton(onClick = onForgot) { Text("Forgot?", color = Color.White.copy(alpha = 0.7f), fontSize = 13.sp) }
                }
                PinKey("0") { press('0') }
                Box(
                    Modifier.size(72.dp).clickable { if (pin.isNotEmpty()) pin = pin.dropLast(1) },
                    contentAlignment = Alignment.Center
                ) { Icon(Icons.AutoMirrored.Filled.Backspace, "Delete", tint = Color.White) }
            }
            Spacer(Modifier.weight(1f))
        }
    }
}

@Composable
private fun PinKey(label: String, onClick: () -> Unit) {
    Box(
        Modifier
            .size(72.dp)
            .background(Color.White.copy(alpha = 0.12f), CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) { Text(label, fontSize = 30.sp, fontWeight = FontWeight.Medium) }
}

/** Asks for a new PIN twice, then hands it to [onChosen]. */
@Composable
fun PinChooserDialog(onDismiss: () -> Unit, onChosen: (String) -> Unit) {
    var first by remember { mutableStateOf<String?>(null) }
    PinPadDialog(title = if (first == null) "Choose a 4-digit PIN" else "Enter the PIN again", onDismiss = onDismiss) { pin ->
        val chosen = first
        when {
            chosen == null -> { first = pin; PinResult.Message("Enter the same PIN again") }
            pin != chosen -> { first = null; PinResult.Message("Those PINs didn't match. Choose a PIN again.") }
            else -> { onChosen(pin); PinResult.Done }
        }
    }
}

/**
 * "Forgot PIN?": the phone's fingerprint, face or screen lock stands in for the PIN on the owner's phone.
 * A phone with no screen lock at all just opens (it isn't protected anyway), as on the iPhone.
 */
fun unlockWithDeviceOwner(
    activity: FragmentActivity,
    title: String = "Open a locked profile",
    subtitle: String = "Use your phone's screen lock instead of the PIN",
    then: () -> Unit
) {
    val allowed = BIOMETRIC_WEAK or DEVICE_CREDENTIAL // the combination every Android version from 9 accepts
    if (BiometricManager.from(activity).canAuthenticate(allowed) != BiometricManager.BIOMETRIC_SUCCESS) {
        then()
        return
    }
    val prompt = BiometricPrompt(activity, ContextCompat.getMainExecutor(activity), object : BiometricPrompt.AuthenticationCallback() {
        override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = then()
    })
    prompt.authenticate(
        BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(allowed)
            .build()
    )
}
