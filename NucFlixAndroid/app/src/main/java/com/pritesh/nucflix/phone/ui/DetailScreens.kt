package com.pritesh.nucflix.phone.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pritesh.nucflix.phone.data.Kind
import com.pritesh.nucflix.phone.data.Library
import com.pritesh.nucflix.phone.data.Movie
import com.pritesh.nucflix.phone.data.MovieInfo
import com.pritesh.nucflix.phone.data.Series
import com.pritesh.nucflix.phone.data.SeriesInfo
import com.pritesh.nucflix.phone.player.Playback

@Composable
private fun DetailHeader(image: String?, title: String, onBack: () -> Unit) {
    Box(Modifier.fillMaxWidth().aspectRatio(16f / 10f)) {
        Artwork(image, title, Modifier.fillMaxSize())
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.4f), Color.Transparent, Color.Black))))
        IconButton(onClick = onBack, modifier = Modifier.statusBarsPadding().padding(4.dp).background(Color.Black.copy(alpha = 0.4f), CircleShape)) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Color.White)
        }
    }
}

@Composable
private fun PlayButton(label: String, onClick: () -> Unit) {
    Button(onClick = onClick, modifier = Modifier.fillMaxWidth().height(48.dp),
        colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black)) {
        Icon(Icons.Filled.PlayArrow, null)
        Text(label, fontWeight = FontWeight.SemiBold)
    }
}

private fun minutes(secs: Double) = "${(secs / 60).toInt().coerceAtLeast(1)} min"

@Composable
fun MovieDetailScreen(library: Library, movie: Movie, open: (Page) -> Unit, onBack: () -> Unit) {
    val context = LocalContext.current
    val downloads = (context.applicationContext as com.pritesh.nucflix.phone.NucFlixApp).downloads
    @Suppress("UNUSED_VARIABLE") val rev = library.revision
    var info by remember(movie.streamId) { mutableStateOf<MovieInfo?>(null) }
    LaunchedEffect(movie.streamId) { info = library.client?.movieInfo(movie.streamId) }
    val progress = library.movieProgress(movie.streamId)
    val resume = progress?.resumeAt ?: 0.0
    val sync = library.sync
    val fav = sync?.isFavorite(Kind.MOVIE, movie.streamId) == true
    LazyColumn(Modifier.fillMaxSize()) {
        item { DetailHeader(info?.backdrop?.ifEmpty { null } ?: movie.icon, movie.cleanName, onBack) }
        item {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(movie.cleanName, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                val meta = listOfNotNull(info?.releaseDate?.take(4)?.ifEmpty { null }, movie.rating.ifEmpty { null }?.let { "★ $it" },
                    info?.durationSecs?.takeIf { it > 0 }?.let { minutes(it.toDouble()) }) + movie.badges
                if (meta.isNotEmpty()) Text(meta.joinToString(" · "), color = NucColors.Muted, fontSize = 13.sp)
                if (resume > 0) {
                    PlayButton("Resume (${minutes(progress!!.duration - resume)} left)") { Playback.movie(context, movie, resume) }
                    Button(onClick = { Playback.movie(context, movie, 0.0) }, modifier = Modifier.fillMaxWidth(),
                        colors = ButtonDefaults.buttonColors(containerColor = NucColors.SurfaceHigh, contentColor = Color.White)) { Text("Start Over") }
                } else PlayButton("Play") { Playback.movie(context, movie, 0.0) }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    MyListButton(fav) { sync?.setFavorite(Kind.MOVIE, movie.streamId, movie.cleanName, movie.icon, movie.ext, movie.categoryId, !fav) }
                    library.line?.let { line ->
                        DownloadButton(downloads, { movieDownload(line.id, movie) }) { open(Page.Downloads) }
                    }
                }
                info?.plot?.takeIf { it.isNotBlank() }?.let { Text(it, fontSize = 14.sp) }
                info?.genre?.takeIf { it.isNotBlank() }?.let { Text("Genre: $it", color = NucColors.Muted, fontSize = 13.sp) }
                info?.cast?.takeIf { it.isNotBlank() }?.let { Text("Cast: $it", color = NucColors.Muted, fontSize = 13.sp, maxLines = 3, overflow = TextOverflow.Ellipsis) }
                info?.director?.takeIf { it.isNotBlank() }?.let { Text("Director: $it", color = NucColors.Muted, fontSize = 13.sp) }
            }
        }
    }
}

@Composable
fun SeriesDetailScreen(library: Library, series: Series, open: (Page) -> Unit, onBack: () -> Unit) {
    val context = LocalContext.current
    val downloads = (context.applicationContext as com.pritesh.nucflix.phone.NucFlixApp).downloads
    @Suppress("UNUSED_VARIABLE") val rev = library.revision
    var info by remember(series.seriesId) { mutableStateOf<SeriesInfo?>(null) }
    var loading by remember(series.seriesId) { mutableStateOf(true) }
    var season by remember(series.seriesId) { mutableStateOf<Int?>(null) }
    LaunchedEffect(series.seriesId) { info = library.seriesInfo(series.seriesId); loading = false }
    val sync = library.sync
    val fav = sync?.isFavorite(Kind.SERIES, series.seriesId) == true
    val progress = library.episodeProgress(series.seriesId)
    val all = info?.allEpisodes.orEmpty()
    // Where to pick up: the latest episode watched (or the one after it, if finished), else the first.
    val latest = sync?.progress?.firstOrNull { it.kind == "episode" && it.seriesId == series.seriesId }
    val latestIdx = latest?.let { l -> all.indexOfFirst { it.episodeId == l.episodeId } } ?: -1
    val (startIdx, startAt) = when {
        latestIdx < 0 -> 0 to 0.0
        latest!!.isWatched && latestIdx + 1 < all.size -> latestIdx + 1 to 0.0
        else -> latestIdx to latest.resumeAt
    }
    val currentSeason = season ?: all.getOrNull(startIdx)?.season ?: info?.seasons?.firstOrNull()

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
        item { DetailHeader(info?.backdrop?.ifEmpty { null } ?: series.backdrop.ifEmpty { series.cover }, series.cleanName, onBack) }
        item {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(series.cleanName, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                val meta = listOfNotNull(series.releaseDate.take(4).ifEmpty { null }, series.rating.ifEmpty { null }?.let { "★ $it" },
                    info?.seasons?.size?.takeIf { it > 0 }?.let { if (it == 1) "1 season" else "$it seasons" })
                if (meta.isNotEmpty()) Text(meta.joinToString(" · "), color = NucColors.Muted, fontSize = 13.sp)
                if (all.isNotEmpty()) {
                    val ep = all[startIdx]
                    val label = if (latestIdx < 0) "Play S${ep.season} E${ep.episodeNum}" else "${if (startAt > 0) "Resume" else "Play"} S${ep.season} E${ep.episodeNum}"
                    PlayButton(label) { Playback.episode(context, series, all, startIdx, startAt) }
                }
                MyListButton(fav) { sync?.setFavorite(Kind.SERIES, series.seriesId, series.cleanName, series.cover, null, series.categoryId, !fav) }
                (info?.plot?.ifBlank { null } ?: series.plot.ifBlank { null })?.let { Text(it, fontSize = 14.sp) }
                if (loading) CircularProgressIndicator(Modifier.align(Alignment.CenterHorizontally), color = NucColors.Red)
                else if (all.isEmpty()) Text("No episodes listed by your provider.", color = NucColors.Muted)
            }
        }
        val seasons = info?.seasons.orEmpty()
        if (seasons.size > 1) item {
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(seasons) { s ->
                    val on = s == currentSeason
                    Text("Season $s", Modifier.clip(RoundedCornerShape(50)).background(if (on) Color.White else NucColors.SurfaceHigh)
                        .clickable { season = s }.padding(horizontal = 14.dp, vertical = 8.dp), color = if (on) Color.Black else Color.White, fontSize = 14.sp)
                }
            }
        }
        items(all.filter { it.season == currentSeason }, key = { it.episodeId }) { ep ->
            val p = progress[ep.episodeId]
            val index = all.indexOf(ep)
            Row(Modifier.fillMaxWidth().clickable { Playback.episode(context, series, all, index, p?.resumeAt ?: 0.0) }.padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.width(128.dp).aspectRatio(16f / 9f).clip(RoundedCornerShape(6.dp))) {
                    Artwork(ep.image.ifEmpty { series.cover }, "E${ep.episodeNum}", Modifier.fillMaxSize())
                    if (p != null && p.duration > 0) {
                        Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).background(Color.White.copy(alpha = 0.3f))) {
                            Box(Modifier.fillMaxHeight().fillMaxWidth(if (p.isWatched) 1f else (p.position / p.duration).toFloat().coerceIn(0.03f, 1f)).background(NucColors.Red))
                        }
                    }
                }
                Column(Modifier.weight(1f).padding(start = 12.dp)) {
                    Text("${ep.episodeNum}. ${ep.cleanTitle}", fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    val sub = listOfNotNull(ep.durationSecs.takeIf { it > 0 }?.let { minutes(it.toDouble()) }, if (p?.isWatched == true) "Watched" else null)
                    if (sub.isNotEmpty()) Text(sub.joinToString(" · "), color = NucColors.Muted, fontSize = 12.sp)
                }
                if (p?.isWatched == true) Icon(Icons.Filled.CheckCircle, "Watched", tint = NucColors.Muted)
                library.line?.let { line -> DownloadIcon(downloads, { episodeDownload(line.id, series, ep) }) { open(Page.Downloads) } }
            }
        }
    }
}
