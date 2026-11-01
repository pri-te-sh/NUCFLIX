package com.pritesh.nucflix.phone.data

import android.content.Context
import android.provider.Settings
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The catalog after the adult / kids filters, with lookups and search. */
class FilteredCatalog(
    val liveCategories: List<Category>, val movieCategories: List<Category>, val seriesCategories: List<Category>,
    val live: List<LiveChannel>, val movies: List<Movie>, val series: List<Series>,
    /** Kids profiles: titles that passed the rules but still wait for their AI check. */
    val kidsPending: List<Triple<Kind, Int, String>>,
    /** Filtering is on (adult content hidden, or a kids profile): history entries must be in the catalog to show. */
    val filtering: Boolean
) {
    val liveById by lazy { live.associateBy { it.streamId } }
    val movieById by lazy { movies.associateBy { it.streamId } }
    val seriesById by lazy { series.associateBy { it.seriesId } }
    val liveByCategory by lazy { live.groupBy { it.categoryId } }
    val moviesByCategory by lazy { movies.groupBy { it.categoryId } }
    val seriesByCategory by lazy { series.groupBy { it.categoryId } }
    private val movieNames by lazy { movies.map { searchNormalize(it.name) } }
    private val seriesNames by lazy { series.map { searchNormalize(it.name) } }
    private val liveNames by lazy { live.map { searchNormalize(it.name) } }

    data class Results(val movies: List<Movie>, val series: List<Series>, val live: List<LiveChannel>)

    /** Titles containing every word of the query; ones that start with it first. */
    fun search(query: String, limit: Int = 60): Results {
        val q = searchNormalize(query)
        if (q.isEmpty()) return Results(emptyList(), emptyList(), emptyList())
        val words = q.split(' ')
        fun <T> pick(items: List<T>, names: List<String>): List<T> {
            val first = ArrayList<T>(); val rest = ArrayList<T>()
            for (i in items.indices) {
                val n = names[i]
                if (words.all { n.contains(it) }) (if (n.startsWith(q) || n.contains(" $q")) first else rest).add(items[i])
                if (first.size >= limit) break
            }
            return (first + rest).take(limit)
        }
        return Results(pick(movies, movieNames), pick(series, seriesNames), pick(live.filterNot { it.isDivider }, liveNames).take(20))
    }

    companion object {
        val EMPTY = FilteredCatalog(emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), false)
    }
}

/** A Continue Watching card: a title in progress, or the next episode of a show whose last episode is finished. */
data class ContinueItem(val progress: Progress, val nextEpisode: Episode? = null) {
    val key: String get() = if (nextEpisode != null) "upnext-${progress.seriesId}" else progress.key
}

/**
 * The active profile's library on the active line: the catalog (cached on disk, refreshed in the background),
 * the filters, My List / progress sync and the shared AI data.
 */
class Library(private val context: Context, private val downloads: DownloadManager) {
    enum class Status { IDLE, LOADING, READY, FAILED }

    var status by mutableStateOf(Status.IDLE); private set
    var error by mutableStateOf<String?>(null); private set
    var catalog by mutableStateOf(FilteredCatalog.EMPTY); private set
    /** Bumped whenever synced data (My List, progress) changes: screens read it to recompose. */
    var revision by mutableIntStateOf(0); private set

    var client: XtreamClient? = null; private set
    var sync: ProfileSync? = null; private set
    var profile: CloudProfile? = null; private set
    var line: CloudLine? = null; private set
    private var smart: SmartData? = null
    private var raw: RawCatalog? = null
    private var sessionKey: String? = null
    private var lineKey: String? = null
    private var filterKey: String? = null
    private val scope = MainScope()
    private var refilterJob: Job? = null
    private var loadJob: Job? = null
    private val upNext = HashMap<Int, Pair<String, Episode?>>() // seriesId -> (episodeId it follows, next episode)
    private val seriesInfoCache = HashMap<Int, SeriesInfo>()

    /** The line this phone streams from right now (downloads wait while it does), set by the player. */
    var streamingLineId: String? = null

    val deviceId by lazy {
        "android-" + (Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID) ?: "device")
    }

    /** Starts (or keeps) the session for this profile + line; cheap to call on every recomposition. */
    fun activate(uid: String, profile: CloudProfile, line: CloudLine) {
        this.profile = profile
        val newSession = "$uid|${profile.id}|${line.id}"
        val newLine = "${line.id}|${line.serverUrl}|${line.username}|${line.password}"
        val newFilter = "${profile.kids}|${profile.showAdult}"
        if (newSession != sessionKey) {
            sessionKey = newSession
            sync?.stop()
            smart?.stop()
            sync = ProfileSync(uid, profile.id, line.id, deviceId, ProfileSync.deviceName()) {
                revision++
                refreshUpNext()
                sync?.let { downloads.removeWatched(it.progress) }
            }.also { it.start() }
            downloads.watchPresence(uid)
            smart = SmartData(uid, line.id) { scheduleRefilter(1500) }.also { it.start(watchKids = profile.kids) }
            upNext.clear()
        }
        if (newLine != lineKey) {
            lineKey = newLine
            this.line = line
            client = XtreamClient(line, context.cacheDir)
            raw = null
            catalog = FilteredCatalog.EMPTY
            load()
            scope.launch { client?.maxConnections()?.let { downloads.maxConnections[line.id] = it } }
        } else if (newFilter != filterKey) {
            scheduleRefilter(0)
        }
        filterKey = newFilter
    }

    fun stop() {
        sync?.stop(); sync = null
        smart?.stop(); smart = null
        sessionKey = null; lineKey = null; filterKey = null
        raw = null; catalog = FilteredCatalog.EMPTY; status = Status.IDLE
    }

    /** Cached catalog first (instant), then a fresh copy when the cache is old or missing. */
    fun load(force: Boolean = false) {
        val c = client ?: return
        loadJob?.cancel()
        loadJob = scope.launch {
            error = null
            val cachedAt = c.cachedAt()
            if (cachedAt > 0 && !force) {
                runCatching { raw = c.catalog(useCache = true) }
                if (raw != null) { refilter(); status = Status.READY }
            }
            if (raw == null) status = Status.LOADING
            if (force || raw == null || System.currentTimeMillis() - cachedAt > REFRESH_AFTER) {
                runCatching { c.catalog(useCache = false) }
                    .onSuccess { raw = it; refilter(); status = Status.READY }
                    .onFailure { if (raw == null) { error = "Couldn't load your provider's catalog. Check your connection and the line."; status = Status.FAILED } }
            }
        }
    }

    private fun scheduleRefilter(delayMs: Long) {
        refilterJob?.cancel()
        refilterJob = scope.launch { delay(delayMs); refilter() }
    }

    private suspend fun refilter() {
        val r = raw ?: return
        val p = profile ?: return
        val s = smart
        catalog = withContext(Dispatchers.Default) { CatalogFilter.apply(r, p, s) }
        revision++
        refreshUpNext()
        // Fill in missing AI data in the background (each title / category only once per household).
        if (s != null) scope.launch {
            s.fillTags(r.liveCategories.map { Kind.LIVE to it } + r.movieCategories.map { Kind.MOVIE to it } + r.seriesCategories.map { Kind.SERIES to it })
            if (p.kids && catalog.kidsPending.isNotEmpty()) s.fillKids { catalog.kidsPending }
        }
    }

    // ---------------------------------------------------------------- derived views

    /** In-progress titles, newest first: one card per show (its latest episode, or the next once that's finished). */
    fun continueWatching(): List<ContinueItem> {
        val s = sync ?: return emptyList()
        val cat = catalog
        val seen = HashSet<Int>()
        val out = ArrayList<ContinueItem>()
        for (p in s.progress) {
            when (p.kind) {
                "movie" -> {
                    if (cat.filtering && p.streamId?.let { cat.movieById[it] } == null) continue
                    if (p.resumeAt > 0) out += ContinueItem(p)
                }
                "episode" -> {
                    val sid = p.seriesId ?: continue
                    if (!seen.add(sid)) continue
                    if (cat.filtering && cat.seriesById[sid] == null) continue
                    if (p.resumeAt > 0) out += ContinueItem(p)
                    else if (p.isWatched) upNext[sid]?.takeIf { it.first == p.episodeId }?.second?.let { out += ContinueItem(p, it) }
                }
            }
            if (out.size >= 20) break
        }
        return out
    }

    /** Looks up the episode after each show's finished latest episode (needs the show's episode list). */
    private fun refreshUpNext() {
        val s = sync ?: return
        val c = client ?: return
        val todo = s.progress.filter { it.kind == "episode" && it.isWatched }.distinctBy { it.seriesId }
            .filter { p -> p.seriesId != null && upNext[p.seriesId]?.first != p.episodeId }.take(6)
        if (todo.isEmpty()) return
        scope.launch {
            for (p in todo) {
                val info = seriesInfo(p.seriesId!!) ?: continue
                val all = info.allEpisodes
                val idx = all.indexOfFirst { it.episodeId == p.episodeId }
                upNext[p.seriesId] = (p.episodeId ?: "") to (if (idx >= 0) all.getOrNull(idx + 1) else null)
            }
            revision++
        }
    }

    /** A category's AI tag (language, genre...), for smart search. */
    fun tag(kind: Kind, categoryId: String): CategoryTag? = smart?.tag(kind, categoryId)

    suspend fun seriesInfo(seriesId: Int): SeriesInfo? =
        seriesInfoCache[seriesId] ?: client?.seriesInfo(seriesId)?.also { seriesInfoCache[seriesId] = it }

    /** Episode progress for a show (episodeId -> progress), for episode lists. */
    fun episodeProgress(seriesId: Int): Map<String, Progress> =
        sync?.progress?.filter { it.kind == "episode" && it.seriesId == seriesId && it.episodeId != null }?.associateBy { it.episodeId!! }.orEmpty()

    fun movieProgress(streamId: Int): Progress? = sync?.progress?.firstOrNull { it.kind == "movie" && it.streamId == streamId }

    /** Removes a Continue Watching card everywhere (for a show, all its episode progress). */
    fun removeFromContinueWatching(item: ContinueItem) {
        val s = sync ?: return
        val p = item.progress
        val keys = if (p.kind == "episode") s.progress.filter { it.kind == "episode" && it.seriesId == p.seriesId }.map { it.key } else listOf(p.key)
        s.deleteProgress(keys)
    }

    data class Row(val title: String, val movies: List<Movie> = emptyList(), val series: List<Series> = emptyList())

    /** Home rows after Continue Watching and My List. */
    fun homeRows(): List<Row> {
        val cat = catalog
        val rows = ArrayList<Row>()
        val newest = cat.movies.sortedByDescending { it.added }.take(30)
        if (newest.isNotEmpty()) rows += Row("New on NucFlix", movies = newest)
        val shows = cat.series.sortedByDescending { it.lastModified }.take(30)
        if (shows.isNotEmpty()) rows += Row("Popular Shows", series = shows)
        val top = cat.movies.filter { (it.rating.toDoubleOrNull() ?: 0.0) >= 7 }.sortedByDescending { it.added }.take(30)
        if (top.size >= 6) rows += Row("Critically Acclaimed", movies = top)
        // A few of the biggest movie and show categories.
        cat.movieCategories.map { it to (cat.moviesByCategory[it.id]?.size ?: 0) }.filter { it.second >= 10 }.sortedByDescending { it.second }
            .take(3).forEach { (c, _) -> rows += Row(c.label, movies = cat.moviesByCategory[c.id].orEmpty().sortedByDescending { it.added }.take(30)) }
        cat.seriesCategories.map { it to (cat.seriesByCategory[it.id]?.size ?: 0) }.filter { it.second >= 10 }.sortedByDescending { it.second }
            .take(2).forEach { (c, _) -> rows += Row(c.label, series = cat.seriesByCategory[c.id].orEmpty().take(30)) }
        return rows
    }

    companion object {
        /** Refresh a cached catalog older than this (new titles appear every few hours). */
        const val REFRESH_AFTER = 6 * 3600 * 1000L
    }
}
