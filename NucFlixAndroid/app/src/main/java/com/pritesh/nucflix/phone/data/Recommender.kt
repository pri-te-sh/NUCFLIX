package com.pritesh.nucflix.phone.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import kotlin.math.max
import kotlin.math.pow

/** A Home feed title: a movie or a show. */
sealed interface FeedItem {
    val id: String; val title: String; val poster: String; val categoryId: String
    data class MovieItem(val movie: Movie) : FeedItem {
        override val id get() = "m${movie.streamId}"; override val title get() = movie.cleanName
        override val poster get() = movie.icon; override val categoryId get() = movie.categoryId
    }
    data class SeriesItem(val series: Series) : FeedItem {
        override val id get() = "s${series.seriesId}"; override val title get() = series.cleanName
        override val poster get() = series.cover; override val categoryId get() = series.categoryId
    }
}

/** A featured title on Home, with why it's there ("Because you watched Dune"). */
data class HeroPick(val item: FeedItem, val reason: String, val tags: List<String>)

data class Rail(val id: String, val title: String, val items: List<FeedItem>, val top10: Boolean = false)

data class HomeFeed(val hero: List<HeroPick>, val rails: List<Rail>, val personalized: Boolean, val builtAt: Long = System.currentTimeMillis())

/** One taste signal: a title was opened, played, mostly watched, added to My List or downloaded. */
data class TasteEvent(val kind: String, val content: Kind, val itemId: Int, val title: String, val categoryId: String?,
                      val genres: List<String>, val at: Long) {
    val weight: Double get() = when (kind) { DETAIL -> 1.0; PLAY -> 3.0; WATCHED -> 5.0; else -> 4.0 }

    companion object {
        const val DETAIL = "detailView"; const val PLAY = "play"; const val WATCHED = "watchedMost"
        const val FAVORITE = "favorite"; const val DOWNLOAD = "download"
    }
}

/**
 * Detail views and downloads, kept on the phone per profile (the newest 400). Plays and My List come from the
 * synced progress and favorites instead, so a new phone is personalised straight away.
 */
class TasteStore(context: Context) {
    private val prefs = context.getSharedPreferences("nucflix.taste", Context.MODE_PRIVATE)

    fun load(profileId: String): List<TasteEvent> = runCatching {
        val arr = JSONArray(prefs.getString(profileId, "[]"))
        (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val content = Kind.entries.firstOrNull { it.key == o.optString("c") } ?: return@mapNotNull null
            val g = o.optJSONArray("g")
            TasteEvent(o.optString("k"), content, o.optInt("i"), o.optString("t"), o.optString("cat").ifEmpty { null },
                (0 until (g?.length() ?: 0)).map { g!!.optString(it) }, o.optLong("at"))
        }
    }.getOrDefault(emptyList())

    @Synchronized
    fun add(profileId: String, e: TasteEvent) {
        val list = (load(profileId) + e).takeLast(400)
        val arr = JSONArray()
        list.forEach { x ->
            arr.put(JSONObject().put("k", x.kind).put("c", x.content.key).put("i", x.itemId).put("t", x.title).put("cat", x.categoryId ?: "")
                .put("g", JSONArray(x.genres)).put("at", x.at))
        }
        prefs.edit().putString(profileId, arr.toString()).apply()
    }
}

/**
 * The iPhone app's on-device recommender: a taste profile (category, genre and title-word affinities, fading over
 * three weeks) scores the catalog, and Home gets a hero carousel and personal rows from it. Runs off the main thread.
 */
object Recommender {
    private const val HALF_LIFE_DAYS = 21.0
    private val stopWords = setOf("the", "a", "an", "of", "and", "in", "on", "to", "for", "with", "part", "season", "movie",
        "hd", "fhd", "uhd", "4k", "1080p", "720p", "hevc", "multi", "sub", "dub", "vf", "vostfr",
        "ii", "iii", "iv", "2", "3", "4", "5", "la", "le", "el", "de", "der", "die", "das")

    fun keywords(title: String) = searchNormalize(title).split(' ').filter { it.length >= 3 && it !in stopWords && it.toIntOrNull() == null }

    fun genres(raw: String?): List<String> = raw.orEmpty().replace('/', ',').replace('&', ',').split(',')
        .map { w -> w.trim().lowercase().split(' ').joinToString(" ") { it.replaceFirstChar(Char::uppercase) } }
        .filter { it.isNotEmpty() && it.length < 24 }

    private fun rating(raw: String): Double = raw.toDoubleOrNull()?.let { if (it > 10) it / 10 else it } ?: 0.0

    /** Varies the feed day to day (and on refresh) but keeps it stable within a session. */
    private fun jitter(id: Int, seed: Int): Double {
        var x = (id.toLong() * 2_654_435_761L + seed.toLong() * 40_503L)
        x = x xor (x ushr 33); x *= -0xae502812aa7333L; x = x xor (x ushr 33)
        return java.lang.Long.remainderUnsigned(x, 10_000) / 10_000.0
    }

    private fun hasArtwork(i: FeedItem) = i.poster.startsWith("http")

    /** At most [perCategory] per category, no repeated titles, nothing in [excluding]. */
    private fun diversified(ranked: List<FeedItem>, perCategory: Int, limit: Int, excluding: Set<String>): List<FeedItem> {
        val counts = HashMap<String, Int>(); val titles = HashSet<String>(); val out = ArrayList<FeedItem>()
        for (item in ranked) {
            if (item.id in excluding) continue
            val n = counts[item.categoryId] ?: 0
            if (n >= perCategory || !titles.add(searchNormalize(item.title))) continue
            counts[item.categoryId] = n + 1
            out += item
            if (out.size >= limit) break
        }
        return out
    }

    private fun timeOfDayTitle(): String = when (Calendar.getInstance().get(Calendar.HOUR_OF_DAY)) {
        in 5..11 -> "Your Morning Picks"; in 12..16 -> "Top Picks for You"; in 17..21 -> "Tonight's Picks for You"; else -> "Late-Night Picks for You"
    }

    /** Local events plus plays (from progress) and My List (from favorites), oldest first. */
    fun events(local: List<TasteEvent>, progress: List<Progress>, favorites: List<Favorite>, cat: FilteredCatalog): List<TasteEvent> {
        val out = ArrayList<TasteEvent>(local)
        for (p in progress) {
            val strong = p.duration > 0 && p.position / p.duration >= 0.5
            val kind = if (strong) TasteEvent.WATCHED else TasteEvent.PLAY
            when (p.kind) {
                "movie" -> p.streamId?.let { id ->
                    val m = cat.movieById[id]
                    out += TasteEvent(kind, Kind.MOVIE, id, m?.name ?: p.title, m?.categoryId, genresKnown(local, Kind.MOVIE, id), p.updatedAt)
                }
                "episode" -> p.seriesId?.let { id ->
                    val s = cat.seriesById[id]
                    out += TasteEvent(kind, Kind.SERIES, id, s?.name ?: p.title, s?.categoryId, genres(s?.genre), p.updatedAt)
                }
            }
        }
        for (f in favorites) when (f.kind) {
            Kind.MOVIE -> cat.movieById[f.id]?.let { out += TasteEvent(TasteEvent.FAVORITE, Kind.MOVIE, f.id, it.name, it.categoryId, genresKnown(local, Kind.MOVIE, f.id), f.addedAt) }
            Kind.SERIES -> cat.seriesById[f.id]?.let { out += TasteEvent(TasteEvent.FAVORITE, Kind.SERIES, f.id, it.name, it.categoryId, genres(it.genre), f.addedAt) }
            Kind.LIVE -> {}
        }
        return out.sortedBy { it.at }
    }

    /** Movie genres only come from their detail pages: reuse what an earlier visit learned. */
    private fun genresKnown(local: List<TasteEvent>, kind: Kind, id: Int) =
        local.lastOrNull { it.content == kind && it.itemId == id && it.genres.isNotEmpty() }?.genres.orEmpty()

    fun build(events: List<TasteEvent>, cat: FilteredCatalog, progress: List<Progress>, refreshSeed: Int): HomeFeed {
        val now = System.currentTimeMillis()
        val catAffRaw = HashMap<String, Double>(); val genreAffRaw = HashMap<String, Double>(); val wordAffRaw = HashMap<String, Double>()
        var total = 0.0
        for (e in events) {
            if (e.content == Kind.LIVE) continue
            val days = max((now - e.at) / 86_400_000.0, 0.0)
            val w = e.weight * 0.5.pow(days / HALF_LIFE_DAYS)
            total += w
            e.categoryId?.takeIf { it.isNotEmpty() }?.let { catAffRaw.merge("${e.content.key}:$it", w, Double::plus) }
            e.genres.forEach { genreAffRaw.merge(it, w, Double::plus) }
            keywords(e.title).forEach { wordAffRaw.merge(it, w * 0.5, Double::plus) }
        }
        fun norm(m: Map<String, Double>): Map<String, Double> { val top = m.values.maxOrNull() ?: return emptyMap(); return if (top > 0) m.mapValues { it.value / top } else emptyMap() }
        val catAff = norm(catAffRaw); val genreAff = norm(genreAffRaw); val wordAff = norm(wordAffRaw)
        val personalized = total > 2.5
        val seed = (now / 86_400_000L).toInt() + refreshSeed * 7919

        // Titles already watched or in progress aren't recommendations.
        val seenMovies = progress.filter { it.kind == "movie" }.mapNotNull { it.streamId }.toHashSet()
        val seenSeries = progress.mapNotNull { it.seriesId }.toHashSet()

        val nowSec = now / 1000
        fun recency(added: Long): Double { if (added <= 0) return 0.0; val d = (nowSec - added) / 86_400.0; return if (d < 0) 0.0 else max(0.0, 1 - d / 60) }
        fun wordScore(title: String) = if (wordAff.isEmpty()) 0.0 else keywords(title).maxOfOrNull { wordAff[it] ?: 0.0 } ?: 0.0
        fun genreScore(raw: String): Double { if (genreAff.isEmpty()) return 0.0; val g = genres(raw); return if (g.isEmpty()) 0.0 else g.sumOf { genreAff[it] ?: 0.0 } / g.size }
        fun scoreMovie(m: Movie) = 3.0 * (catAff["movie:${m.categoryId}"] ?: 0.0) + 1.2 * wordScore(m.name) + 0.9 * rating(m.rating) / 10 +
            0.8 * recency(m.added) + 0.35 * jitter(m.streamId, seed)
        fun scoreSeries(s: Series) = 3.0 * (catAff["series:${s.categoryId}"] ?: 0.0) + 2.0 * genreScore(s.genre) + 1.2 * wordScore(s.name) +
            0.9 * rating(s.rating) / 10 + 0.6 * recency(s.lastModified) + 0.35 * jitter(s.seriesId, seed)

        // Candidates: the strongest categories (bounded work) plus the newest arrivals.
        val topMovieCats = catAff.filterKeys { it.startsWith("movie:") }.entries.sortedByDescending { it.value }.take(8).map { it.key.removePrefix("movie:") }
        val topSeriesCats = catAff.filterKeys { it.startsWith("series:") }.entries.sortedByDescending { it.value }.take(8).map { it.key.removePrefix("series:") }
        val freshMovies = cat.movies.filter { it.added > 0 }.sortedByDescending { it.added }.take(400)
        val freshSeries = cat.series.sortedByDescending { it.lastModified }.take(300)
        var moviePool = topMovieCats.flatMap { cat.moviesByCategory[it].orEmpty() } + freshMovies
        var seriesPool = topSeriesCats.flatMap { cat.seriesByCategory[it].orEmpty() } + freshSeries
        if (moviePool.size < 200) moviePool = moviePool + cat.movies.take(600)
        if (seriesPool.size < 150) seriesPool = seriesPool + cat.series.take(400)
        moviePool = moviePool.distinctBy { it.streamId }.filter { it.streamId !in seenMovies }
        seriesPool = seriesPool.distinctBy { it.seriesId }.filter { it.seriesId !in seenSeries }
        val rankedMovies = moviePool.map { it to scoreMovie(it) }.sortedByDescending { it.second }
        val rankedSeries = seriesPool.map { it to scoreSeries(it) }.sortedByDescending { it.second }
        val blended = (rankedMovies.take(250).map { FeedItem.MovieItem(it.first) to it.second } +
            rankedSeries.take(250).map { FeedItem.SeriesItem(it.first) to it.second }).sortedByDescending { it.second }
        val blendedItems = blended.map { it.first }

        val used = HashSet<String>()
        val rails = ArrayList<Rail>()
        val movieCatNames = cat.movieCategories.associate { it.id to it.cleanName }
        val seriesCatNames = cat.seriesCategories.associate { it.id to it.cleanName }

        // Hero: the top picks with artwork.
        val lastWatched = events.lastOrNull { it.kind != TasteEvent.DETAIL && it.content != Kind.LIVE }?.title
        var heroCandidates = blendedItems.filter(::hasArtwork)
        if (!personalized) heroCandidates = diversified(heroCandidates, 1, 12, emptySet())
        val hero = diversified(heroCandidates, 2, 6, emptySet()).mapIndexed { i, item ->
            val reason = when {
                !personalized -> if (i == 0) "New on NucFlix" else "Trending Now"
                i == 0 -> "#1 Pick for You"
                i == 1 && lastWatched != null -> "Because you watched ${XtreamFormatter.format(lastWatched).cleanTitle}"
                else -> "Recommended for You"
            }
            val tags = when (item) {
                is FeedItem.MovieItem -> listOfNotNull("Film", movieCatNames[item.movie.categoryId], rating(item.movie.rating).takeIf { it >= 0.1 }?.let { "★ %.1f".format(it) })
                is FeedItem.SeriesItem -> (listOf("Series") + genres(item.series.genre).take(2)).let { t ->
                    if (t.size < 3) t + listOfNotNull(seriesCatNames[item.series.categoryId]) else t }
            }
            used += item.id
            HeroPick(item, reason, tags.take(4))
        }

        val topPicks = diversified(blendedItems, if (personalized) 4 else 2, 20, used)
        if (topPicks.isNotEmpty()) {
            rails += Rail("top-picks", if (personalized) timeOfDayTitle() else "Popular on NucFlix", topPicks)
            topPicks.take(8).forEach { used += it.id }
        }

        // "Because you watched X" for the last two titles watched (not just opened).
        val anchors = events.asReversed().filter { it.kind != TasteEvent.DETAIL && it.content != Kind.LIVE }.distinctBy { "${it.content}-${it.itemId}" }.take(2)
        for (a in anchors) {
            val aWords = keywords(a.title).toSet(); val aGenres = a.genres.toSet()
            fun similarity(title: String, catId: String?, genreRaw: String?, r: Double, id: Int): Double {
                val words = keywords(title).toSet()
                val overlap = if (aWords.isEmpty()) 0.0 else words.intersect(aWords).size.toDouble() / aWords.size
                val g = genres(genreRaw).toSet()
                val gOverlap = if (aGenres.isEmpty() || g.isEmpty()) 0.0 else g.intersect(aGenres).size.toDouble() / aGenres.size
                val sameCat = if (catId != null && catId == a.categoryId) 1.0 else 0.0
                return 2.5 * overlap + 2.0 * gOverlap + 1.2 * sameCat + 0.4 * (r / 10) + 0.2 * jitter(id, seed)
            }
            val similar = ArrayList<Pair<FeedItem, Double>>()
            val sameMovies = cat.moviesByCategory[a.categoryId].orEmpty().let { if (a.content == Kind.MOVIE) it else it.take(200) }
            val sameSeries = cat.seriesByCategory[a.categoryId].orEmpty().let { if (a.content == Kind.SERIES) it else it.take(200) }
            sameMovies.take(1500).filter { it.streamId != a.itemId && it.streamId !in seenMovies }
                .forEach { similar += FeedItem.MovieItem(it) to similarity(it.name, it.categoryId, null, rating(it.rating), it.streamId) }
            sameSeries.take(1500).filter { it.seriesId != a.itemId && it.seriesId !in seenSeries }
                .forEach { similar += FeedItem.SeriesItem(it) to similarity(it.name, it.categoryId, it.genre, rating(it.rating), it.seriesId) }
            if (aGenres.isNotEmpty()) rankedSeries.take(300).filter { it.first.seriesId != a.itemId }
                .forEach { (s, _) -> similar += FeedItem.SeriesItem(s) to similarity(s.name, s.categoryId, s.genre, rating(s.rating), s.seriesId) }
            val items = diversified(similar.sortedByDescending { it.second }.map { it.first }, 12, 18, used)
            if (items.size >= 4) {
                rails += Rail("byw-${a.content.key}-${a.itemId}", "Because you watched ${XtreamFormatter.format(a.title).cleanTitle}", items)
                items.take(6).forEach { used += it.id }
            }
        }

        // New arrivals, leaning towards the categories you watch.
        val fresh = (freshMovies.take(250).map { FeedItem.MovieItem(it) to recency(it.added) + 0.8 * (catAff["movie:${it.categoryId}"] ?: 0.0) } +
            freshSeries.take(150).map { FeedItem.SeriesItem(it) to recency(it.lastModified) + 0.8 * (catAff["series:${it.categoryId}"] ?: 0.0) })
            .sortedByDescending { it.second }.map { it.first }.filter(::hasArtwork)
        diversified(fresh, 5, 18, used).takeIf { it.size >= 4 }?.let { rails += Rail("new", "New on NucFlix", it) }

        diversified(rankedSeries.map { FeedItem.SeriesItem(it.first) }.filter(::hasArtwork), 3, 10, used).takeIf { it.size >= 5 }?.let { top ->
            rails += Rail("top10", "Top 10 Shows for You Today", top, top10 = true)
            top.forEach { used += it.id }
        }

        if (personalized) genreAff.maxByOrNull { it.value }?.key?.let { g ->
            diversified(rankedSeries.filter { g in genres(it.first.genre) }.map { FeedItem.SeriesItem(it.first) }, 6, 18, used)
                .takeIf { it.size >= 4 }?.let { rails += Rail("genre-$g", "$g Shows You'll Love", it) }
        }

        topMovieCats.firstOrNull()?.let { c ->
            val name = movieCatNames[c] ?: return@let
            diversified(cat.moviesByCategory[c].orEmpty().sortedByDescending(::scoreMovie).map { FeedItem.MovieItem(it) }, 30, 18, used)
                .takeIf { it.size >= 4 }?.let { rails += Rail("cat-$c", "More from $name", it) }
        }

        val acclaimed = blended.filter { (i, _) -> rating(if (i is FeedItem.MovieItem) i.movie.rating else (i as FeedItem.SeriesItem).series.rating) >= 7.5 }
            .map { it.first }.filter(::hasArtwork)
        diversified(acclaimed, 4, 18, used).takeIf { it.size >= 4 }?.let { rails += Rail("acclaimed", "Critically Acclaimed", it) }

        return HomeFeed(hero, rails, personalized)
    }
}
