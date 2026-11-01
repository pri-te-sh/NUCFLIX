package com.pritesh.nucflix.phone.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pritesh.nucflix.phone.data.Epg
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** "What's on now" under a channel's name; the guide loads once the row has been on screen for a moment. */
@Composable
fun NowOn(epg: Epg, streamId: Int) {
    LaunchedEffect(streamId) { delay(300); epg.load(streamId) } // fast scrolling past a row doesn't fetch its guide
    val now = epg.now(streamId)
    if (now != null) Text(now.title, fontSize = 12.sp, color = NucColors.Red, maxLines = 1, overflow = TextOverflow.Ellipsis)
}

/** A channel's schedule: what's on now (with how far in it is), then what's next. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GuideSheet(epg: Epg, channelName: String, streamId: Int, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    LaunchedEffect(streamId) { epg.load(streamId) }
    // From what's on now (some providers also list programmes that already ended).
    val listings = epg.listings(streamId)?.let { all -> val now = System.currentTimeMillis() / 1000; all.filter { it.stop <= 0 || it.stop > now } }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = NucColors.Surface) {
        Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(channelName, fontWeight = FontWeight.Bold, fontSize = 18.sp, modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            IconButton(onClick = { scope.launch { epg.load(streamId, force = true) } }) { Icon(Icons.Filled.Refresh, "Refresh guide", tint = Color.White) }
        }
        when {
            listings == null -> Box(Modifier.fillMaxWidth().padding(40.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = NucColors.Red) }
            listings.isEmpty() -> Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("No TV guide", fontWeight = FontWeight.SemiBold)
                Text("This channel doesn't publish its schedule.", color = NucColors.Muted, fontSize = 14.sp)
            }
            else -> LazyColumn(Modifier.heightIn(max = 560.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 20.dp, end = 20.dp, bottom = 32.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)) {
                items(listings, key = { "${it.start}-${it.title}" }) { p ->
                    val live = p.isNow()
                    Column(Modifier.fillMaxWidth()) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (live) Text("LIVE NOW", fontSize = 10.sp, fontWeight = FontWeight.Black, color = Color.Black,
                                modifier = Modifier.background(NucColors.Red, RoundedCornerShape(50)).padding(horizontal = 7.dp, vertical = 1.dp))
                            Text(p.timeRange(), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = if (live) NucColors.Red else NucColors.Muted)
                        }
                        Text(p.title, fontWeight = FontWeight.Bold, fontSize = 15.sp, modifier = Modifier.padding(top = 3.dp))
                        if (p.description.isNotEmpty()) Text(p.description, fontSize = 13.sp, color = Color.White.copy(alpha = 0.75f), maxLines = 4,
                            overflow = TextOverflow.Ellipsis)
                        if (live) LinearProgressIndicator({ p.progress() }, Modifier.fillMaxWidth().padding(top = 6.dp), color = NucColors.Red,
                            trackColor = Color.White.copy(alpha = 0.15f))
                    }
                }
            }
        }
    }
}
