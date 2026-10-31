package com.pritesh.nucflix.phone.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pritesh.nucflix.phone.data.CloudProfile

object NucColors {
    val Red = Color(0xFFE50914)
    val Background = Color(0xFF000000)
    val Surface = Color(0xFF141414)
    val SurfaceHigh = Color(0xFF232323)
    val Muted = Color(0xFFB3B3B3)
    val Green = Color(0xFF46D369)

    /** Profile colours, the same keys and shades as the iPhone and TV apps. */
    fun avatar(key: String): Color = when (key) {
        "blue" -> Color(0xFF1F80E0)
        "green" -> Color(0xFF299E5C)
        "yellow" -> Color(0xFFF2B81A)
        "purple" -> Color(0xFF7A47D9)
        "orange" -> Color(0xFFF5731A)
        "teal" -> Color(0xFF1A999E)
        "pink" -> Color(0xFFED4D94)
        else -> Red
    }
}

@Composable
fun NucFlixTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = NucColors.Red,
            onPrimary = Color.White,
            background = NucColors.Background,
            onBackground = Color.White,
            surface = NucColors.Surface,
            onSurface = Color.White,
            surfaceVariant = NucColors.SurfaceHigh,
            onSurfaceVariant = NucColors.Muted,
            error = Color(0xFFFF6B6B)
        )
    ) {
        // Text is white unless a screen says otherwise (the default is black, outside a Surface).
        CompositionLocalProvider(LocalContentColor provides Color.White, content = content)
    }
}

@Composable
fun Wordmark(modifier: Modifier = Modifier, size: Int = 28) {
    Text("NUCFLIX", modifier = modifier, color = NucColors.Red, fontSize = size.sp, fontWeight = FontWeight.Black, letterSpacing = 1.sp)
}

/** A profile's coloured square with its initial (and a KIDS badge). */
@Composable
fun ProfileAvatar(profile: CloudProfile, size: Dp, modifier: Modifier = Modifier) {
    Box(
        modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.09f))
            .background(NucColors.avatar(profile.avatar)),
        contentAlignment = Alignment.Center
    ) {
        Text(
            profile.name.take(1).uppercase(), color = Color.White,
            fontSize = (size.value * 0.46f).sp, fontWeight = FontWeight.Black
        )
        if (profile.kids) {
            Text(
                "KIDS",
                Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = size * 0.07f)
                    .clip(RoundedCornerShape(50))
                    .background(Color.White)
                    .padding(horizontal = 8.dp, vertical = 2.dp),
                color = Color.Black, fontSize = (size.value * 0.11f).sp, fontWeight = FontWeight.Black
            )
        }
    }
}
