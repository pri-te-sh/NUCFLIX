package com.pritesh.nucflix.phone.ui

import android.app.Activity
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCode
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pritesh.nucflix.phone.data.CloudAccount
import kotlinx.coroutines.launch

/** Sign in or create the household account (the same account as the iPhone app). */
@Composable
fun AuthScreen(cloud: CloudAccount) {
    val scope = rememberCoroutineScope()
    val activity = LocalContext.current as Activity
    var creating by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var notice by remember { mutableStateOf<String?>(null) }
    var withAnotherDevice by remember { mutableStateOf(false) }

    if (withAnotherDevice) {
        BackHandler { withAnotherDevice = false }
        DeviceSignInScreen { withAnotherDevice = false }
        return
    }

    Column(
        Modifier
            .fillMaxSize()
            .safeDrawingPadding()
            .imePadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 28.dp, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Spacer(Modifier.height(24.dp))
        Wordmark(size = 40)
        Text(
            "One account for your phone and TVs: profiles, My List and Continue Watching follow you everywhere.",
            color = NucColors.Muted, textAlign = TextAlign.Center, fontSize = 15.sp
        )
        Spacer(Modifier.height(8.dp))
        Text(if (creating) "Create your account" else "Sign in", fontSize = 24.sp, fontWeight = FontWeight.Bold)
        if (creating) {
            OutlinedTextField(name, { name = it }, label = { Text("Your name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        }
        OutlinedTextField(
            email, { email = it }, label = { Text("Email") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email, imeAction = ImeAction.Next)
        )
        OutlinedTextField(
            password, { password = it }, label = { Text("Password") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done)
        )
        cloud.error?.let { Text(it, color = androidx.compose.material3.MaterialTheme.colorScheme.error, fontSize = 14.sp) }
        notice?.let { Text(it, color = NucColors.Green, fontSize = 14.sp) }
        Button(
            onClick = {
                notice = null
                scope.launch { if (creating) cloud.signUp(name, email, password) else cloud.signIn(email, password) }
            },
            enabled = !cloud.busy && email.isNotBlank() && password.isNotEmpty() && (!creating || name.isNotBlank()),
            modifier = Modifier.fillMaxWidth().height(50.dp),
            colors = ButtonDefaults.buttonColors(containerColor = NucColors.Red)
        ) {
            if (cloud.busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            else Text(if (creating) "Create Account" else "Sign In", fontWeight = FontWeight.SemiBold)
        }
        OutlinedButton(
            onClick = { notice = null; scope.launch { cloud.signInWithGoogle(activity) } },
            enabled = !cloud.busy,
            modifier = Modifier.fillMaxWidth().height(50.dp)
        ) { Text("Continue with Google") }
        OutlinedButton(
            onClick = { notice = null; cloud.error = null; withAnotherDevice = true },
            enabled = !cloud.busy,
            modifier = Modifier.fillMaxWidth().height(50.dp)
        ) {
            Icon(Icons.Filled.QrCode, null, Modifier.size(20.dp))
            Text("  Sign in with another device")
        }
        TextButton(onClick = { creating = !creating; cloud.error = null; notice = null }) {
            Text(if (creating) "Already have an account? Sign in" else "New to NucFlix? Create an account", color = androidx.compose.ui.graphics.Color.White)
        }
        if (!creating) {
            TextButton(
                onClick = {
                    scope.launch { if (cloud.sendPasswordReset(email)) notice = "Check your email for a link to reset your password." }
                },
                enabled = email.isNotBlank() && !cloud.busy
            ) { Text("Forgot password?", color = NucColors.Muted) }
        }
    }
}
