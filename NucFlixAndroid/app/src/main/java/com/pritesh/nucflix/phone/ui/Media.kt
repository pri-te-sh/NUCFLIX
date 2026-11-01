package com.pritesh.nucflix.phone.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage

/** Artwork, or the title on a dark tile while it loads / when there's none. */
@Composable
fun Artwork(url: String?, title: String, modifier: Modifier = Modifier, fit: Boolean = false) {
    Box(modifier.background(NucColors.SurfaceHigh), contentAlignment = Alignment.Center) {
        val fallback = @Composable {
            Text(title, Modifier.padding(8.dp), fontSize = 12.sp, color = Color.White.copy(alpha = 0.75f),
                textAlign = TextAlign.Center, maxLines = 4, overflow = TextOverflow.Ellipsis)
        }
        if (url.isNullOrBlank()) fallback()
        else SubcomposeAsyncImage(
            model = url, contentDescription = title, modifier = Modifier.fillMaxSize(),
            contentScale = if (fit) ContentScale.Fit else ContentScale.Crop,
            loading = { fallback() }, error = { fallback() }
        )
    }
}

/** A 2:3 poster. */
@Composable
fun Poster(url: String?, title: String, width: Dp = 110.dp, onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
    Artwork(
        url, title,
        Modifier.width(width).aspectRatio(2f / 3f).clip(RoundedCornerShape(6.dp))
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
    )
}

/** A 2:3 poster that fills its grid cell. */
@Composable
fun GridPoster(url: String?, title: String, onClick: () -> Unit) {
    Artwork(url, title, Modifier.fillMaxWidth().aspectRatio(2f / 3f).clip(RoundedCornerShape(6.dp)).clickable(onClick = onClick))
}

/** A 16:9 card with a progress bar and caption (Continue Watching). */
@Composable
fun ProgressCard(url: String?, title: String, caption: String, fraction: Float, onLongClick: (() -> Unit)?, onClick: () -> Unit) {
    Column(Modifier.width(200.dp).combinedClickable(onClick = onClick, onLongClick = onLongClick)) {
        Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(6.dp))) {
            Artwork(url, title, Modifier.fillMaxSize())
            Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(4.dp).background(Color.White.copy(alpha = 0.25f))) {
                Box(Modifier.fillMaxHeight().fillMaxWidth(fraction.coerceIn(0.03f, 1f)).background(NucColors.Red))
            }
        }
        Text(title, Modifier.padding(top = 6.dp), fontSize = 13.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(caption, fontSize = 12.sp, color = NucColors.Muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** A live channel: its logo (fitted) and name. */
@Composable
fun ChannelTile(url: String?, name: String, width: Dp = 140.dp, onClick: () -> Unit) {
    Column(Modifier.width(width).clickable(onClick = onClick)) {
        Artwork(url, name, Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(6.dp)), fit = true)
        Text(name, Modifier.padding(top = 4.dp), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** A titled horizontal row. */
@Composable
fun <T> MediaRow(title: String, items: List<T>, key: (T) -> Any, action: String? = null, onAction: () -> Unit = {}, content: @Composable (T) -> Unit) {
    if (items.isEmpty()) return
    Column(Modifier.padding(top = 18.dp)) {
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(title, Modifier.weight(1f), fontSize = 17.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (action != null) Text(action, Modifier.clickable(onClick = onAction).padding(start = 12.dp), fontSize = 13.sp, color = NucColors.Muted)
        }
        // A new first item (e.g. a title just watched) is shown, not left just off the start of the row.
        val state = rememberLazyListState()
        val first = key(items.first())
        LaunchedEffect(first) { if (state.firstVisibleItemIndex <= 1) state.scrollToItem(0) }
        LazyRow(state = state, contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(items, key = key) { content(it) }
        }
    }
}
