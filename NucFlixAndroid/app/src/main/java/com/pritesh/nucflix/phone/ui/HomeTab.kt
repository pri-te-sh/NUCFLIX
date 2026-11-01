package com.pritesh.nucflix.phone.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.foundation.interaction.collectIsDraggedAsState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pritesh.nucflix.phone.data.ContinueItem
import com.pritesh.nucflix.phone.data.FeedItem
import com.pritesh.nucflix.phone.data.HeroPick
import com.pritesh.nucflix.phone.data.Kind
import com.pritesh.nucflix.phone.data.Library
import com.pritesh.nucflix.phone.player.Playback
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/** Home: featured picks, Continue Watching, My List, Live TV, then rows picked for this profile. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeTab(library: Library, open: (Page) -> Unit, onSeeAllLive: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    @Suppress("UNUSED_VARIABLE") val rev = library.revision // recompose when My List / progress change
    val cat = library.catalog
    val sync = library.sync
    val feed = library.feed
    val cw = library.continueWatching()
    var removing by remember { mutableStateOf<ContinueItem?>(null) }
    var clearing by remember { mutableStateOf(false) }
    // Back on Home after a while: freshen the picks (a varied mix, like the iPhone app).
    LaunchedEffect(Unit) { if (feed != null && System.currentTimeMillis() - feed.builtAt > 10 * 60_000) library.refreshFeed(reshuffle = true) }
    val myList = sync?.favorites.orEmpty().mapNotNull { f ->
        when (f.kind) {
            Kind.MOVIE -> cat.movieById[f.id]?.let { FeedItem.MovieItem(it) }
            Kind.SERIES -> cat.seriesById[f.id]?.let { FeedItem.SeriesItem(it) }
            Kind.LIVE -> null
        }
    }
    val favChannels = sync?.favorites.orEmpty().filter { it.kind == Kind.LIVE }.mapNotNull { cat.liveById[it.id] }
    val openItem: (FeedItem) -> Unit = { i -> open(if (i is FeedItem.MovieItem) Page.MovieDetail(i.movie) else Page.SeriesDetail((i as FeedItem.SeriesItem).series)) }

    if (cat.movies.isEmpty() && cat.series.isEmpty() && cat.live.isEmpty()) {
        Message(if (cat.kidsPending.isNotEmpty()) "Getting things ready: checking titles so only kid-friendly ones show. The first time takes a few minutes."
                else "Nothing here yet. Your provider returned no titles.")
        return
    }
    PullToRefreshBox(isRefreshing = library.refreshing, onRefresh = { library.refreshFeed(reshuffle = true); library.load(force = true) }) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
            // The hero's slot is there from the start (dark until the picks are in): a slot added above the rows later
            // would leave the list scrolled past it.
            when {
                feed == null -> item(key = "hero") { Box(Modifier.fillMaxWidth().aspectRatio(0.8f).background(NucColors.Surface)) }
                feed.hero.isNotEmpty() -> item(key = "hero") { HeroCarousel(library, feed.hero, openItem) }
            }
            item(key = "cw") {
                MediaRow("Continue Watching", cw, key = { it.key }, action = if (cw.size > 1) "Clear" else null, onAction = { clearing = true }) { item ->
                    val p = item.progress
                    val next = item.nextEpisode
                    val caption = when {
                        next != null -> "Next: S${next.season} E${next.episodeNum}"
                        p.subtitle != null -> p.subtitle
                        else -> "${((p.duration - p.position) / 60).toInt().coerceAtLeast(1)} min left"
                    }
                    ProgressCard(p.artwork, p.title, caption, if (next != null) 0f else (p.position / p.duration).toFloat(), onLongClick = { removing = item }) {
                        scope.launch { resume(context, library, item, open) }
                    }
                }
            }
            item(key = "mylist") { MediaRow("My List", myList, key = { it.id }) { i -> Poster(i.poster, i.title) { openItem(i) } } }
            item(key = "live") {
                MediaRow("Live TV", favChannels.ifEmpty { cat.live.filterNot { it.isDivider }.take(15) }, key = { it.streamId }, action = "See All", onAction = onSeeAllLive) { c ->
                    ChannelTile(c.icon, c.cleanName) { Playback.live(context, c, library.epg.now(c.streamId)?.title) }
                }
            }
            feed?.rails?.forEach { rail ->
                item(key = rail.id) {
                    if (rail.top10) MediaRow(rail.title, rail.items.withIndex().toList(), key = { it.value.id }) { (i, item) -> TopTenTile(i + 1, item) { openItem(item) } }
                    else MediaRow(rail.title, rail.items, key = { it.id }) { i -> Poster(i.poster, i.title) { openItem(i) } }
                }
            }
        }
    }
    removing?.let { item ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text("Remove ${item.progress.title} from Continue Watching?") },
            text = { Text(if (item.progress.kind == "episode") "It goes from every device, and this show's episode progress is cleared." else "It goes from every device.") },
            confirmButton = { TextButton(onClick = { library.removeFromContinueWatching(item); removing = null }) { Text("Remove", color = NucColors.Red) } },
            dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel", color = Color.White) } }
        )
    }
    if (clearing) AlertDialog(
        onDismissRequest = { clearing = false },
        title = { Text("Clear Continue Watching?") },
        text = { Text("All ${cw.size} titles go from every device, and their progress is cleared.") },
        confirmButton = { TextButton(onClick = { cw.forEach(library::removeFromContinueWatching); clearing = false }) { Text("Clear", color = NucColors.Red) } },
        dismissButton = { TextButton(onClick = { clearing = false }) { Text("Cancel", color = Color.White) } }
    )
}

/** Up to six featured titles, each with why it's there; turns every 7 seconds unless you're swiping. */
@Composable
private fun HeroCarousel(library: Library, picks: List<HeroPick>, openItem: (FeedItem) -> Unit) {
    val context = LocalContext.current
    val pager = rememberPagerState { picks.size }
    val dragged = pager.interactionSource.collectIsDraggedAsState()
    // Restarts once a page has settled (after a turn or a swipe); keying on "scrolling" would cancel each turn as it starts.
    LaunchedEffect(pager, picks.size) {
        if (picks.size < 2) return@LaunchedEffect
        snapshotFlow { pager.settledPage to dragged.value }.collectLatest { (page, dragging) ->
            if (dragging) return@collectLatest
            delay(7_000)
            pager.animateScrollToPage((page + 1) % picks.size)
        }
    }
    val sync = library.sync
    Column {
        HorizontalPager(pager, Modifier.fillMaxWidth().aspectRatio(0.8f), key = { picks[it].item.id }) { page ->
            val pick = picks[page]
            val item = pick.item
            val (kind, id) = when (item) { is FeedItem.MovieItem -> Kind.MOVIE to item.movie.streamId; is FeedItem.SeriesItem -> Kind.SERIES to item.series.seriesId }
            val fav = sync?.isFavorite(kind, id) == true
            Box(Modifier.fillMaxSize().clickable { openItem(item) }) {
                Artwork(item.poster, item.title, Modifier.fillMaxSize())
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black), startY = 300f)))
                Column(Modifier.align(Alignment.BottomCenter).padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(pick.reason.uppercase(), fontSize = 11.sp, fontWeight = FontWeight.Black, color = NucColors.Red, letterSpacing = 1.sp)
                    Text(item.title, fontSize = 26.sp, fontWeight = FontWeight.Black, maxLines = 2, overflow = TextOverflow.Ellipsis,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                    if (pick.tags.isNotEmpty()) Text(pick.tags.joinToString("  •  "), fontSize = 12.sp, color = Color.White.copy(alpha = 0.8f), maxLines = 1,
                        overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 4.dp))
                    Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Button(onClick = {
                            when (item) {
                                is FeedItem.MovieItem -> Playback.movie(context, item.movie, library.movieProgress(item.movie.streamId)?.resumeAt ?: 0.0)
                                is FeedItem.SeriesItem -> openItem(item) // the show page picks the episode to start with
                            }
                        }, colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black)) {
                            Icon(Icons.Filled.PlayArrow, null); Text(if (item is FeedItem.MovieItem) "Play" else "Episodes", fontWeight = FontWeight.SemiBold)
                        }
                        OutlinedButton(onClick = {
                            when (item) {
                                is FeedItem.MovieItem -> sync?.setFavorite(Kind.MOVIE, id, item.title, item.poster, item.movie.ext, item.categoryId, !fav)
                                is FeedItem.SeriesItem -> sync?.setFavorite(Kind.SERIES, id, item.title, item.poster, null, item.categoryId, !fav)
                            }
                        }) {
                            Icon(if (fav) Icons.Filled.Check else Icons.Filled.Add, null, tint = Color.White)
                            Text(" My List", color = Color.White)
                        }
                    }
                }
            }
        }
        if (picks.size > 1) Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.Center) {
            repeat(picks.size) { i ->
                Box(Modifier.padding(horizontal = 3.dp).size(if (i == pager.currentPage) 8.dp else 6.dp).clip(CircleShape)
                    .background(if (i == pager.currentPage) Color.White else Color.White.copy(alpha = 0.35f)))
            }
        }
    }
}

/** A Top 10 entry: a big outlined rank beside the poster. */
@Composable
private fun TopTenTile(rank: Int, item: FeedItem, onClick: () -> Unit) {
    Box(Modifier.width(if (rank == 10) 168.dp else 150.dp).clickable(onClick = onClick)) {
        Text("$rank", Modifier.align(Alignment.BottomStart).offset(y = 18.dp), fontSize = 110.sp, fontWeight = FontWeight.Black, color = Color.White,
            style = TextStyle(drawStyle = Stroke(width = 5f)), letterSpacing = (-8).sp)
        Artwork(item.poster, item.title, Modifier.align(Alignment.BottomEnd).width(100.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(6.dp)))
    }
}
