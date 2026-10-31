package com.pritesh.nucflix.phone.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pritesh.nucflix.phone.data.CloudAccount
import com.pritesh.nucflix.phone.data.ContinueItem
import com.pritesh.nucflix.phone.data.Kind
import com.pritesh.nucflix.phone.data.Library
import com.pritesh.nucflix.phone.data.LiveChannel
import com.pritesh.nucflix.phone.data.Movie
import com.pritesh.nucflix.phone.data.Series
import com.pritesh.nucflix.phone.player.Playback
import kotlinx.coroutines.launch

/** Pages opened over the tabs (Back returns). */
sealed interface Page {
    data class MovieDetail(val movie: Movie) : Page
    data class SeriesDetail(val series: Series) : Page
    data object Account : Page
    data object Lines : Page
    data object PairTv : Page
}

private enum class Tab(val label: String, val icon: ImageVector) {
    HOME("Home", Icons.Filled.Home), SHOWS("Shows", Icons.Filled.Tv), MOVIES("Movies", Icons.Filled.Movie),
    LIVE("Live TV", Icons.Filled.LiveTv), SEARCH("Search", Icons.Filled.Search)
}

@Composable
fun MainScreen(cloud: CloudAccount, library: Library) {
    var tab by rememberSaveable { mutableStateOf(Tab.HOME) }
    val pages = remember { mutableStateListOf<Page>() }
    val open: (Page) -> Unit = { pages.add(it) }
    BackHandler(pages.isNotEmpty()) { pages.removeAt(pages.lastIndex) }
    BackHandler(pages.isEmpty() && tab != Tab.HOME) { tab = Tab.HOME }

    when (val page = pages.lastOrNull()) {
        is Page.MovieDetail -> { MovieDetailScreen(library, page.movie) { pages.removeAt(pages.lastIndex) }; return }
        is Page.SeriesDetail -> { SeriesDetailScreen(library, page.series) { pages.removeAt(pages.lastIndex) }; return }
        Page.Account -> { AccountScreen(cloud, library, open) { pages.removeAt(pages.lastIndex) }; return }
        Page.Lines -> { LinesScreen(cloud) { pages.removeAt(pages.lastIndex) }; return }
        Page.PairTv -> { PairTvScreen(cloud) { pages.removeAt(pages.lastIndex) }; return }
        null -> Unit
    }
    val profile = cloud.selectedProfile ?: return

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Wordmark(size = 24)
            Spacer(Modifier.weight(1f))
            ProfileAvatar(profile, 32.dp, Modifier.clickable { open(Page.Account) })
        }
        Box(Modifier.weight(1f)) {
            when {
                library.status == Library.Status.FAILED -> Message(library.error ?: "Couldn't load the catalog.", "Try Again") { library.load(force = true) }
                library.status != Library.Status.READY -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        CircularProgressIndicator(color = NucColors.Red)
                        Text("Loading ${library.line?.name ?: "your line"}…", Modifier.padding(top = 12.dp), color = NucColors.Muted)
                    }
                }
                else -> when (tab) {
                    Tab.HOME -> HomeTab(library, open)
                    Tab.SHOWS -> BrowseTab(library, Kind.SERIES, open)
                    Tab.MOVIES -> BrowseTab(library, Kind.MOVIE, open)
                    Tab.LIVE -> LiveTab(library)
                    Tab.SEARCH -> SearchTab(library, open)
                }
            }
        }
        NavigationBar(containerColor = NucColors.Background) {
            Tab.entries.forEach { t ->
                NavigationBarItem(
                    selected = tab == t, onClick = { tab = t }, icon = { Icon(t.icon, null) }, label = { Text(t.label, fontSize = 11.sp) },
                    colors = NavigationBarItemDefaults.colors(selectedIconColor = Color.White, selectedTextColor = Color.White,
                        indicatorColor = NucColors.SurfaceHigh, unselectedIconColor = NucColors.Muted, unselectedTextColor = NucColors.Muted)
                )
            }
        }
    }
}

@Composable
fun Message(text: String, action: String? = null, onAction: () -> Unit = {}) {
    Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Text(text, color = NucColors.Muted, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        if (action != null) TextButton(onClick = onAction) { Text(action) }
    }
}

// ---------------------------------------------------------------- Home

@Composable
private fun HomeTab(library: Library, open: (Page) -> Unit) {
    val context = LocalContext.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    @Suppress("UNUSED_VARIABLE") val rev = library.revision // recompose when My List / progress change
    val cat = library.catalog
    val sync = library.sync
    val cw = library.continueWatching()
    val rows = remember(cat) { library.homeRows() }
    // The featured title: the newest movie with artwork (stable across catalog refreshes, unlike a random pick).
    val hero = remember(cat) { cat.movies.sortedByDescending { it.added }.let { l -> l.firstOrNull { it.icon.isNotBlank() } ?: l.firstOrNull() } }
    var removing by remember { mutableStateOf<ContinueItem?>(null) }
    val myList = sync?.favorites.orEmpty().mapNotNull { f ->
        when (f.kind) {
            Kind.MOVIE -> cat.movieById[f.id]?.let { Triple("m${f.id}", it.icon, it.cleanName) to { open(Page.MovieDetail(it)) } }
            Kind.SERIES -> cat.seriesById[f.id]?.let { Triple("s${f.id}", it.cover, it.cleanName) to { open(Page.SeriesDetail(it)) } }
            Kind.LIVE -> null
        }
    }
    val favChannels = sync?.favorites.orEmpty().filter { it.kind == Kind.LIVE }.mapNotNull { cat.liveById[it.id] }

    if (cat.movies.isEmpty() && cat.series.isEmpty() && cat.live.isEmpty()) {
        Message(if (cat.kidsPending.isNotEmpty()) "Getting things ready: checking titles so only kid-friendly ones show. The first time takes a few minutes."
                else "Nothing here yet. Your provider returned no titles.")
        return
    }
    LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
        hero?.let { h ->
            item {
                Box(Modifier.fillMaxWidth().aspectRatio(0.8f)) {
                    Artwork(h.icon, h.cleanName, Modifier.fillMaxSize())
                    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black), startY = 300f)))
                    Column(Modifier.align(Alignment.BottomCenter).padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(h.cleanName, fontSize = 26.sp, fontWeight = FontWeight.Black, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Button(onClick = { Playback.movie(context, h, library.movieProgress(h.streamId)?.resumeAt ?: 0.0) },
                                colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black)) {
                                Icon(Icons.Filled.PlayArrow, null); Text("Play", fontWeight = FontWeight.SemiBold)
                            }
                            OutlinedButton(onClick = { open(Page.MovieDetail(h)) }) { Text("More Info", color = Color.White) }
                        }
                    }
                }
            }
        }
        item {
            MediaRow("Continue Watching", cw, key = { it.key }) { item ->
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
        item {
            MediaRow("My List", myList, key = { it.first.first }) { (t, go) -> Poster(t.second, t.third, onClick = go) }
        }
        item {
            MediaRow("Live TV", favChannels.ifEmpty { cat.live.take(15) }, key = { it.streamId }) { c -> ChannelTile(c.icon, c.cleanName) { Playback.live(context, c) } }
        }
        rows.forEach { row ->
            item {
                if (row.movies.isNotEmpty()) MediaRow(row.title, row.movies, key = { it.streamId }) { m -> Poster(m.icon, m.cleanName) { open(Page.MovieDetail(m)) } }
                else MediaRow(row.title, row.series, key = { it.seriesId }) { s -> Poster(s.cover, s.cleanName) { open(Page.SeriesDetail(s)) } }
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
}

/** Plays a Continue Watching card: a movie or episode from where it stopped, or the next episode. */
private suspend fun resume(context: android.content.Context, library: Library, item: ContinueItem, open: (Page) -> Unit) {
    val p = item.progress
    val cat = library.catalog
    if (p.kind == "movie") {
        val m = p.streamId?.let { cat.movieById[it] } ?: return
        Playback.movie(context, m, p.resumeAt)
        return
    }
    val s = p.seriesId?.let { cat.seriesById[it] } ?: return
    // The show's episode list gives the stream URL and lets the player go on to the next episode.
    val episodes = library.seriesInfo(s.seriesId)?.allEpisodes
    val target = item.nextEpisode?.episodeId ?: p.episodeId
    val index = episodes?.indexOfFirst { it.episodeId == target } ?: -1
    if (episodes == null || index < 0) { open(Page.SeriesDetail(s)); return }
    Playback.episode(context, s, episodes, index, if (item.nextEpisode != null) 0.0 else p.resumeAt)
}

// ---------------------------------------------------------------- Shows / Movies

@Composable
private fun BrowseTab(library: Library, kind: Kind, open: (Page) -> Unit) {
    val cat = library.catalog
    val categories = if (kind == Kind.MOVIE) cat.movieCategories else cat.seriesCategories
    var selected by rememberSaveable(kind) { mutableStateOf<String?>(null) }
    var picking by remember { mutableStateOf(false) }
    Column {
        LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            item {
                FilterChip(selected = false, onClick = { picking = true }, label = { Text("All ${categories.size} categories") },
                    leadingIcon = { Icon(Icons.Filled.Search, null, Modifier.size(16.dp)) })
            }
            item { CategoryChip("Everything", selected == null) { selected = null } }
            items(categories.take(40), key = { it.id }) { c -> CategoryChip(c.label, selected == c.id) { selected = c.id } }
        }
        val title = categories.firstOrNull { it.id == selected }?.label
        LazyVerticalGrid(GridCells.Adaptive(108.dp), contentPadding = PaddingValues(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (title != null) item(span = { GridItemSpan(maxLineSpan) }) { Text(title, fontSize = 18.sp, fontWeight = FontWeight.Bold) }
            if (kind == Kind.MOVIE) {
                val list = (selected?.let { cat.moviesByCategory[it] } ?: cat.movies).let { l -> if (selected == null) l.sortedByDescending { it.added } else l }
                items(list, key = { it.streamId }) { m -> GridPoster(m.icon, m.cleanName) { open(Page.MovieDetail(m)) } }
            } else {
                val list = selected?.let { cat.seriesByCategory[it] } ?: cat.series.sortedByDescending { it.lastModified }
                items(list, key = { it.seriesId }) { s -> GridPoster(s.cover, s.cleanName) { open(Page.SeriesDetail(s)) } }
            }
        }
    }
    if (picking) CategoryPicker(categories, onDismiss = { picking = false }) { selected = it; picking = false }
}

@Composable
private fun CategoryChip(label: String, selected: Boolean, onClick: () -> Unit) {
    FilterChip(selected = selected, onClick = onClick, label = { Text(label, maxLines = 1) },
        colors = FilterChipDefaults.filterChipColors(selectedContainerColor = Color.White, selectedLabelColor = Color.Black))
}

/** Every category, searchable (there can be hundreds). */
@Composable
fun CategoryPicker(categories: List<com.pritesh.nucflix.phone.data.Category>, onDismiss: () -> Unit, onPick: (String) -> Unit) {
    var filter by remember { mutableStateOf("") }
    androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(NucColors.Background).statusBarsPadding().padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Categories", fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                TextButton(onClick = onDismiss) { Text("Close", color = Color.White) }
            }
            OutlinedTextField(filter, { filter = it }, placeholder = { Text("Filter categories") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            val q = filter.trim().lowercase()
            LazyColumn(Modifier.padding(top = 8.dp)) {
                items(categories.filter { q.isEmpty() || it.label.lowercase().contains(q) }, key = { it.id }) { c ->
                    Text(c.label, Modifier.fillMaxWidth().clickable { onPick(c.id) }.padding(vertical = 14.dp), fontSize = 16.sp)
                }
            }
        }
    }
}

// ---------------------------------------------------------------- Live TV

@Composable
private fun LiveTab(library: Library) {
    val context = LocalContext.current
    @Suppress("UNUSED_VARIABLE") val rev = library.revision
    val cat = library.catalog
    val sync = library.sync
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    var picking by remember { mutableStateOf(false) }
    val favorites = sync?.favorites.orEmpty().filter { it.kind == Kind.LIVE }.mapNotNull { cat.liveById[it.id] }
    val channels: List<LiveChannel> = when (selected) {
        null -> favorites.ifEmpty { cat.live.take(200) }
        else -> cat.liveByCategory[selected].orEmpty()
    }
    Column {
        LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            item {
                FilterChip(selected = false, onClick = { picking = true }, label = { Text("All ${cat.liveCategories.size} categories") },
                    leadingIcon = { Icon(Icons.Filled.Search, null, Modifier.size(16.dp)) })
            }
            item { CategoryChip(if (favorites.isNotEmpty()) "★ Favorites" else "Channels", selected == null) { selected = null } }
            items(cat.liveCategories.take(40), key = { it.id }) { c -> CategoryChip(c.label, selected == c.id) { selected = c.id } }
        }
        LazyColumn(contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            items(channels, key = { it.streamId }) { c ->
                val fav = sync?.isFavorite(Kind.LIVE, c.streamId) == true
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(NucColors.Surface).clickable { Playback.live(context, c) }.padding(8.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Artwork(c.icon, c.cleanName, Modifier.width(96.dp).aspectRatio(16f / 9f).clip(RoundedCornerShape(4.dp)), fit = true)
                    Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                        Text(c.cleanName, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (c.badges.isNotEmpty()) Text(c.badges.joinToString(" · "), fontSize = 12.sp, color = NucColors.Muted)
                    }
                    IconButton(onClick = { sync?.setFavorite(Kind.LIVE, c.streamId, c.cleanName, c.icon, null, c.categoryId, !fav) }) {
                        Icon(if (fav) Icons.Filled.Star else Icons.Filled.StarBorder, if (fav) "Remove favourite" else "Add favourite",
                            tint = if (fav) Color(0xFFF5C518) else NucColors.Muted)
                    }
                }
            }
        }
    }
    if (picking) CategoryPicker(cat.liveCategories, onDismiss = { picking = false }) { selected = it; picking = false }
}

// ---------------------------------------------------------------- Search

@Composable
private fun SearchTab(library: Library, open: (Page) -> Unit) {
    val context = LocalContext.current
    var query by rememberSaveable { mutableStateOf("") }
    val results = remember(query, library.catalog) { library.catalog.search(query) }
    Column {
        OutlinedTextField(query, { query = it }, placeholder = { Text("Search shows, movies, channels") }, singleLine = true,
            leadingIcon = { Icon(Icons.Filled.Search, null) }, modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp))
        if (query.isBlank()) { Message("Find a title or channel by name."); return }
        if (results.movies.isEmpty() && results.series.isEmpty() && results.live.isEmpty()) { Message("No results for \"$query\"."); return }
        LazyVerticalGrid(GridCells.Adaptive(108.dp), contentPadding = PaddingValues(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (results.live.isNotEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Column {
                        Text("Channels", fontWeight = FontWeight.Bold, modifier = Modifier.padding(bottom = 6.dp))
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            items(results.live, key = { it.streamId }) { c -> ChannelTile(c.icon, c.cleanName, 120.dp) { Playback.live(context, c) } }
                        }
                    }
                }
            }
            if (results.series.isNotEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }) { Text("Shows", fontWeight = FontWeight.Bold) }
                items(results.series, key = { "s${it.seriesId}" }) { s -> GridPoster(s.cover, s.cleanName) { open(Page.SeriesDetail(s)) } }
            }
            if (results.movies.isNotEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }) { Text("Movies", fontWeight = FontWeight.Bold) }
                items(results.movies, key = { "m${it.streamId}" }) { m -> GridPoster(m.icon, m.cleanName) { open(Page.MovieDetail(m)) } }
            }
        }
    }
}

/** A "+ My List" / "✓ My List" toggle. */
@Composable
fun MyListButton(on: Boolean, onToggle: () -> Unit) {
    OutlinedButton(onClick = onToggle) {
        Icon(if (on) Icons.Filled.Check else Icons.Filled.Add, null, tint = Color.White)
        Text(" My List", color = Color.White)
    }
}
