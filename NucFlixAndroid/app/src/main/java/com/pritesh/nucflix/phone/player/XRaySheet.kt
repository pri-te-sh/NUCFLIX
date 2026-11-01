package com.pritesh.nucflix.phone.player

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.PersonSearch
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pritesh.nucflix.phone.data.SmartAI
import com.pritesh.nucflix.phone.ui.Artwork
import com.pritesh.nucflix.phone.ui.NucColors
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

private val XRayBlue = Color(0xFF1EC8FF)

/** Trivia and actor pages already loaded, for the app's lifetime. */
private object XRayCache {
    val trivia = mutableMapOf<String, List<String>>()
    val people = mutableMapOf<Int, SmartAI.XRayPersonDetail>()
}

/**
 * X-Ray, as on Prime Video: who's in the paused scene (face matching in the xray Cloud Function against the title's
 * TMDB cast), trivia from the title's Wikipedia article, and the full cast, which is also what shows when nobody on
 * screen is recognised. An actor opens their bio and best-known titles; Back returns to the list.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun XRaySheet(heading: String, subheading: String, load: suspend () -> SmartAI.XRayScene?, onDismiss: () -> Unit) {
    var loading by remember { mutableStateOf(true) }
    var result by remember { mutableStateOf<SmartAI.XRayScene?>(null) }
    var trivia by remember { mutableStateOf<List<String>>(emptyList()) }
    var person by remember { mutableStateOf<SmartAI.XRayPerson?>(null) }
    LaunchedEffect(Unit) {
        result = load()
        loading = false
        val title = result?.title
        if (title != null && title.hasTrivia) {
            val key = "${title.type}_${title.id}"
            trivia = XRayCache.trivia[key] ?: SmartAI.xrayTrivia(title.type, title.id).also { XRayCache.trivia[key] = it }
        }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = NucColors.Surface) {
        // Inside the sheet (its own window), so Back on an actor's page returns to the list instead of closing X-Ray.
        BackHandler(enabled = person != null) { person = null }
        val p = person
        if (p != null) PersonPage(p) { person = null }
        else LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Badge()
                    Text(heading, fontSize = 22.sp, fontWeight = FontWeight.Bold, color = Color.White)
                    Text(subheading, fontSize = 13.sp, color = NucColors.Muted)
                }
            }
            val r = result
            val title = r?.title
            when {
                loading -> item {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        CircularProgressIndicator(Modifier.size(22.dp), color = Color.White, strokeWidth = 2.dp)
                        Text("Looking at this scene…", color = NucColors.Muted)
                    }
                }
                r == null || title == null -> item {
                    Note(if (r == null) "X-Ray couldn’t load right now. Check the connection and try again." else "X-Ray couldn’t find this title’s cast.")
                }
                else -> {
                    val scene = r.scene.orEmpty()
                    item { Heading("In this scene") }
                    if (scene.isEmpty()) item {
                        val why = when {
                            r.scene == null -> "X-Ray couldn’t see this scene."
                            r.faces > 0 -> "X-Ray doesn’t recognise anyone on screen right now."
                            else -> "Nobody is on screen right now."
                        }
                        Note("$why Here’s the full cast of ${title.name}${if (title.year.isNotEmpty()) " (${title.year})" else ""}.")
                    }
                    items(scene, key = { "scene-${it.id}" }) { PersonRow(it, large = true) { person = it } }
                    if (trivia.isNotEmpty()) {
                        item { Heading("Trivia") }
                        items(trivia) { fact ->
                            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).clip(RoundedCornerShape(8.dp)).background(NucColors.SurfaceHigh)) {
                                Box(Modifier.width(3.dp).fillMaxHeight().background(XRayBlue))
                                Text(fact, Modifier.padding(horizontal = 12.dp, vertical = 10.dp), fontSize = 14.sp, color = Color.White.copy(alpha = 0.9f))
                            }
                        }
                    }
                    item { Heading(if (scene.isEmpty()) "Cast" else "All cast") }
                    if (r.cast.isEmpty()) item { Note("No cast listed.") }
                    items(r.cast, key = { "cast-${it.id}" }) { PersonRow(it, large = false) { person = it } }
                }
            }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

@Composable
private fun Badge() {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(Icons.Filled.PersonSearch, null, tint = XRayBlue, modifier = Modifier.size(18.dp))
        Text("X-RAY", color = XRayBlue, fontWeight = FontWeight.ExtraBold, fontSize = 13.sp, letterSpacing = 1.5.sp)
    }
}

@Composable
private fun Heading(text: String) = Text(text, Modifier.padding(top = 8.dp), fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Color.White)

@Composable
private fun Note(text: String) = Text(text, fontSize = 14.sp, color = NucColors.Muted)

@Composable
private fun PersonRow(p: SmartAI.XRayPerson, large: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).clickable(onClick = onClick).padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Artwork(p.photo, initials(p.name), Modifier.size(if (large) 60.dp else 44.dp, if (large) 80.dp else 58.dp).clip(RoundedCornerShape(8.dp)))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(p.name, fontWeight = FontWeight.SemiBold, fontSize = if (large) 17.sp else 15.sp, color = Color.White)
            if (p.character.isNotEmpty()) Text(p.character, fontSize = if (large) 14.sp else 13.sp, color = NucColors.Muted,
                maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

private fun initials(name: String) = name.split(' ').filter { it.isNotEmpty() }.take(2).joinToString("") { it.take(1) }

private fun date(iso: String): String = runCatching {
    LocalDate.parse(iso).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG))
}.getOrDefault(iso)

/** An actor: photo, birth details, biography, and their best-known titles. */
@Composable
private fun PersonPage(p: SmartAI.XRayPerson, onBack: () -> Unit) {
    var detail by remember(p.id) { mutableStateOf(XRayCache.people[p.id]) }
    var loading by remember(p.id) { mutableStateOf(detail == null) }
    LaunchedEffect(p.id) {
        if (detail == null) {
            detail = SmartAI.xrayPerson(p.id)?.also { XRayCache.people[p.id] = it }
            loading = false
        }
    }
    LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back to X-Ray", tint = Color.White) }
                Badge()
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Artwork(detail?.photo?.takeIf { it.isNotEmpty() } ?: p.photo, initials(p.name),
                    Modifier.size(120.dp, 170.dp).clip(RoundedCornerShape(12.dp)))
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(p.name, fontSize = 22.sp, fontWeight = FontWeight.Bold, color = Color.White)
                    if (p.character.isNotEmpty()) Text("as ${p.character}", fontSize = 14.sp, color = NucColors.Muted)
                    detail?.let { d ->
                        if (d.born.isNotEmpty()) Text("Born  ${date(d.born)}${if (d.place.isNotEmpty()) " in ${d.place}" else ""}", fontSize = 13.sp, color = Color.White)
                        if (d.died.isNotEmpty()) Text("Died  ${date(d.died)}", fontSize = 13.sp, color = Color.White)
                    }
                }
            }
        }
        val d = detail
        when {
            loading -> item { CircularProgressIndicator(Modifier.size(22.dp), color = Color.White, strokeWidth = 2.dp) }
            d == null -> item { Note("Couldn’t load more about this person right now.") }
            else -> {
                item { Text(d.bio.ifEmpty { "No biography yet." }, fontSize = 14.sp, color = if (d.bio.isEmpty()) NucColors.Muted else Color.White.copy(alpha = 0.9f)) }
                if (d.credits.isNotEmpty()) {
                    item { Heading("Known for") }
                    item {
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            items(d.credits) { c ->
                                Column(Modifier.width(104.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Artwork(c.poster, c.title, Modifier.size(104.dp, 156.dp).clip(RoundedCornerShape(8.dp)))
                                    Text(c.title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text(listOf(c.year, c.character).filter { it.isNotEmpty() }.joinToString(" • "), fontSize = 11.sp,
                                        color = NucColors.Muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                            }
                        }
                    }
                }
            }
        }
        item { Spacer(Modifier.height(24.dp)) }
    }
}
