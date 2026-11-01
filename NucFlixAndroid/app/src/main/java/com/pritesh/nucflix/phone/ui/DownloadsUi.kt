package com.pritesh.nucflix.phone.ui

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.DownloadDone
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pritesh.nucflix.phone.NucFlixApp
import com.pritesh.nucflix.phone.data.DownloadItem
import com.pritesh.nucflix.phone.data.DownloadManager
import com.pritesh.nucflix.phone.data.Episode
import com.pritesh.nucflix.phone.data.Library
import com.pritesh.nucflix.phone.data.Movie
import com.pritesh.nucflix.phone.data.Series
import com.pritesh.nucflix.phone.player.Playback

fun movieDownload(lineId: String, m: Movie) = DownloadItem(
    "movie:${m.streamId}", lineId, "movie", m.cleanName, null, m.icon, m.streamId, null, null, null, null, m.ext, DownloadItem.State.QUEUED
)

fun episodeDownload(lineId: String, s: Series, e: Episode) = DownloadItem(
    "episode:${e.episodeId}", lineId, "episode", s.cleanName, "S${e.season} E${e.episodeNum} • ${e.cleanTitle}", s.cover,
    null, s.seriesId, e.episodeId, e.season, e.episodeNum, e.ext, DownloadItem.State.QUEUED
)

/** Starts a download, first asking for permission to show its progress notification (Android 13+). */
@Composable
fun rememberDownloader(downloads: DownloadManager): (DownloadItem) -> Unit {
    val pending = androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf<DownloadItem?>(null) }
    // Downloads go ahead either way; the answer only decides whether their notification shows.
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { pending.value?.let(downloads::enqueue); pending.value = null }
    return { item ->
        if (Build.VERSION.SDK_INT >= 33) { pending.value = item; ask.launch(Manifest.permission.POST_NOTIFICATIONS) } else downloads.enqueue(item)
    }
}

/** The download state of one title, as an icon button (download / waiting / progress / done). */
@Composable
fun DownloadIcon(downloads: DownloadManager, item: () -> DownloadItem, onOpenDownloads: () -> Unit) {
    val start = rememberDownloader(downloads)
    val d = downloads.items.firstOrNull { it.id == item().id }
    IconButton(onClick = { if (d == null) start(item()) else onOpenDownloads() }) {
        when (d?.state) {
            null -> Icon(Icons.Filled.Download, "Download", tint = Color.White)
            DownloadItem.State.DONE -> Icon(Icons.Filled.DownloadDone, "Downloaded", tint = NucColors.Green)
            DownloadItem.State.DOWNLOADING -> CircularProgressIndicator(progress = { d.fraction }, Modifier.size(22.dp), color = NucColors.Red, strokeWidth = 2.5.dp)
            DownloadItem.State.FAILED -> Icon(Icons.Filled.ErrorOutline, "Download failed", tint = NucColors.Red)
            else -> Icon(Icons.Filled.Schedule, "Waiting to download", tint = NucColors.Muted)
        }
    }
}

/** A labelled download button for a movie page. */
@Composable
fun DownloadButton(downloads: DownloadManager, item: () -> DownloadItem, onOpenDownloads: () -> Unit) {
    val start = rememberDownloader(downloads)
    val d = downloads.items.firstOrNull { it.id == item().id }
    OutlinedButton(onClick = { if (d == null) start(item()) else onOpenDownloads() }) {
        val (icon, label) = when (d?.state) {
            null -> Icons.Filled.Download to "Download"
            DownloadItem.State.DONE -> Icons.Filled.DownloadDone to "Downloaded"
            DownloadItem.State.DOWNLOADING -> Icons.Filled.Download to "Downloading ${(d.fraction * 100).toInt()}%"
            DownloadItem.State.WAITING_FOR_LINE -> Icons.Filled.Schedule to "Waiting for the line"
            DownloadItem.State.PAUSED -> Icons.Filled.Pause to "Paused"
            DownloadItem.State.FAILED -> Icons.Filled.ErrorOutline to "Download failed"
            DownloadItem.State.QUEUED -> Icons.Filled.Schedule to "Queued"
        }
        Icon(icon, null, tint = Color.White)
        Text(" $label", color = Color.White)
    }
}

/** Everything downloaded or queued on this phone. */
@Composable
fun DownloadsScreen(library: Library, onBack: () -> Unit) {
    val context = LocalContext.current
    val downloads = (context.applicationContext as NucFlixApp).downloads
    SubScreen("Downloads", onBack) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item {
                Row(Modifier.fillMaxWidth().background(NucColors.Surface, RoundedCornerShape(8.dp)).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Delete Watched Episodes", fontWeight = FontWeight.Medium)
                        Text("Free up space: an episode goes once it's watched on any device", color = NucColors.Muted, fontSize = 12.sp)
                    }
                    Switch(downloads.deleteWatched, downloads::changeDeleteWatched, colors = SwitchDefaults.colors(checkedTrackColor = NucColors.Red))
                }
            }
            if (downloads.items.any { it.state == DownloadItem.State.WAITING_FOR_LINE }) item {
                Text("Paused while ${downloads.watching.joinToString(" and ").ifEmpty { "someone" }} ${if (downloads.watching.size > 1) "are" else "is"} " +
                    "watching on this line (it allows a limited number of connections). Downloads carry on afterwards.",
                    color = Color(0xFFF5C518), fontSize = 13.sp)
            }
            if (downloads.items.isEmpty()) item { Text("Download movies and episodes to watch them without using your line.", color = NucColors.Muted) }
            items(downloads.items, key = { it.id }) { d ->
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(NucColors.Surface)
                    .clickable(enabled = d.state == DownloadItem.State.DONE) { playDownload(context, library, d) }.padding(8.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.width(64.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(4.dp))) { Artwork(d.artwork, d.title, Modifier.fillMaxSize()) }
                    Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                        Text(d.title, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        d.subtitle?.let { Text(it, fontSize = 12.sp, color = NucColors.Muted, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                        val mb = { b: Long -> "%.0f MB".format(b / 1048576.0) }
                        Text(when (d.state) {
                            DownloadItem.State.DONE -> "Downloaded · ${mb(d.total)}"
                            DownloadItem.State.DOWNLOADING -> "${(d.fraction * 100).toInt()}% · ${mb(d.bytes)}${if (d.total > 0) " of ${mb(d.total)}" else ""}"
                            DownloadItem.State.WAITING_FOR_LINE -> "Waiting for the line"
                            DownloadItem.State.QUEUED -> if (d.bytes > 0) "Queued · ${(d.fraction * 100).toInt()}%" else "Queued"
                            DownloadItem.State.PAUSED -> "Paused · ${(d.fraction * 100).toInt()}%"
                            DownloadItem.State.FAILED -> d.error ?: "Failed"
                        }, fontSize = 12.sp, color = if (d.state == DownloadItem.State.FAILED) NucColors.Red else NucColors.Muted)
                    }
                    when (d.state) {
                        DownloadItem.State.DONE -> IconButton(onClick = { playDownload(context, library, d) }) { Icon(Icons.Filled.PlayArrow, "Play", tint = Color.White) }
                        DownloadItem.State.PAUSED, DownloadItem.State.FAILED -> IconButton(onClick = { downloads.resume(d.id) }) { Icon(Icons.Filled.Refresh, "Resume", tint = Color.White) }
                        else -> IconButton(onClick = { downloads.pause(d.id) }) { Icon(Icons.Filled.Pause, "Pause", tint = Color.White) }
                    }
                    IconButton(onClick = { downloads.remove(d.id) }) { Icon(Icons.Filled.Delete, "Delete", tint = NucColors.Muted) }
                }
            }
        }
    }
}

/** Plays a finished download (from the catalog item when it's still listed, so progress and next episodes work). */
private fun playDownload(context: android.content.Context, library: Library, d: DownloadItem) {
    val cat = library.catalog
    if (d.kind == "movie") {
        val m = d.streamId?.let { cat.movieById[it] } ?: Movie(d.streamId ?: 0, d.title, d.title, emptyList(), d.artwork.orEmpty(), "", 0, "", d.ext, false)
        Playback.movie(context, m, library.movieProgress(m.streamId)?.resumeAt ?: 0.0)
        return
    }
    val s = d.seriesId?.let { cat.seriesById[it] } ?: return
    val ep = Episode(d.episodeId ?: return, d.season ?: 1, d.episode ?: 1, d.subtitle ?: "", d.subtitle?.substringAfter("• ") ?: "", d.ext, "", "", 0)
    Playback.episode(context, s, listOf(ep), 0, library.episodeProgress(s.seriesId)[ep.episodeId]?.resumeAt ?: 0.0)
}
