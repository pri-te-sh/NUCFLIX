package com.pritesh.nucflix.phone.data

import android.net.Uri
import android.util.JsonReader
import android.util.JsonToken
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/** The provider's player API for one line: catalog lists (cached on disk), details and stream URLs. */
class XtreamClient(private val line: CloudLine, private val cacheRoot: File) {
    // Lines are saved with the scheme that worked (https or http), which normalizedBaseUrl keeps.
    private val base = Xtream.normalizedBaseUrl(line.serverUrl)
    private val user = Uri.encode(line.username.trim())
    private val pass = Uri.encode(line.password.trim())

    /** One folder per line; the cached lists hold no login (only titles, ids and artwork). */
    private val cacheDir = File(cacheRoot, "catalog-" + sha1("${line.id}|$base|${line.username}")).apply { mkdirs() }

    fun apiUrl(action: String?, extra: Map<String, String> = emptyMap()): String {
        val b = StringBuilder("$base/player_api.php?username=$user&password=$pass")
        if (action != null) b.append("&action=").append(action)
        extra.forEach { (k, v) -> b.append('&').append(k).append('=').append(Uri.encode(v)) }
        return b.toString()
    }

    fun liveUrl(streamId: Int) = "$base/live/$user/$pass/$streamId.ts"
    fun movieUrl(m: Movie) = "$base/movie/$user/$pass/${m.streamId}.${m.ext.ifBlank { "mp4" }}"
    fun movieUrl(streamId: Int, ext: String?) = "$base/movie/$user/$pass/$streamId.${ext?.ifBlank { null } ?: "mp4"}"
    fun episodeUrl(episodeId: String, ext: String?) = "$base/series/$user/$pass/$episodeId.${ext?.ifBlank { null } ?: "mp4"}"

    /** The subscription as the provider reports it (user_info). */
    data class AccountInfo(val username: String, val status: String, val expiresAt: Long?, val activeConnections: Int?, val maxConnections: Int?,
                           val trial: Boolean, val server: String)

    suspend fun accountInfo(): AccountInfo? = withContext(Dispatchers.IO) {
        runCatching {
            val u = JSONObject(fetchText(apiUrl(null))).optJSONObject("user_info") ?: return@runCatching null
            fun num(k: String) = u.optString(k).toDoubleOrNull()?.toLong()
            AccountInfo(u.optString("username"), u.optString("status").ifEmpty { "Active" }, num("exp_date")?.takeIf { it > 0 },
                num("active_cons")?.toInt(), num("max_connections")?.toInt()?.takeIf { it > 0 }, u.optString("is_trial") == "1", base)
        }.getOrNull()
    }

    /** Connections the provider allows at once (user_info.max_connections), or null when it doesn't say. */
    suspend fun maxConnections(): Int? = accountInfo()?.maxConnections

    /** When the cached lists were saved (0 = never). */
    fun cachedAt(): Long = File(cacheDir, "get_vod_streams.json").takeIf { it.exists() }?.lastModified() ?: 0

    /** The whole catalog: from the cache when [useCache] and it's there, else downloaded (and cached). */
    suspend fun catalog(useCache: Boolean): RawCatalog = coroutineScope {
        val liveCats = async { categories("get_live_categories", useCache) }
        val movieCats = async { categories("get_vod_categories", useCache) }
        val seriesCats = async { categories("get_series_categories", useCache) }
        val live = async { list("get_live_streams", useCache, ::liveChannel) }
        val movies = async { list("get_vod_streams", useCache, ::movie) }
        val series = async { list("get_series", useCache, ::series) }
        RawCatalog(liveCats.await(), live.await(), movieCats.await(), movies.await(), seriesCats.await(), series.await())
    }

    private suspend fun categories(action: String, useCache: Boolean) = list(action, useCache) { o ->
        val raw = o.str("category_name").ifEmpty { "Uncategorized" }
        val f = XtreamFormatter.format(raw)
        Category(o.str("category_id").ifEmpty { "0" }, raw, f.cleanTitle, f.prefixTag)
    }

    /** Streams the provider's JSON array into the cache file, then parses it object by object (lists are big). */
    private suspend fun <T> list(action: String, useCache: Boolean, map: (Map<String, Any?>) -> T?): List<T> = withContext(Dispatchers.IO) {
        val file = File(cacheDir, "$action.json")
        if (!useCache || !file.exists()) {
            val tmp = File(cacheDir, "$action.tmp")
            val conn = open(apiUrl(action))
            try {
                conn.inputStream.use { input -> tmp.outputStream().use { input.copyTo(it) } }
            } finally {
                conn.disconnect()
            }
            if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
        }
        val out = ArrayList<T>()
        runCatching {
            JsonReader(InputStreamReader(FileInputStream(file), Charsets.UTF_8)).use { r ->
                if (r.peek() != JsonToken.BEGIN_ARRAY) return@use
                r.beginArray()
                while (r.hasNext()) {
                    if (r.peek() == JsonToken.BEGIN_OBJECT) map(readObject(r))?.let(out::add) else r.skipValue()
                }
                r.endArray()
            }
        }
        out
    }

    suspend fun seriesInfo(seriesId: Int): SeriesInfo? = withContext(Dispatchers.IO) {
        runCatching {
            val root = JSONObject(fetchText(apiUrl("get_series_info", mapOf("series_id" to seriesId.toString()))))
            val info = root.optJSONObject("info") ?: JSONObject()
            val bySeason = linkedMapOf<Int, List<Episode>>()
            when (val eps = root.opt("episodes")) {
                is JSONObject -> eps.keys().forEach { k ->
                    val arr = eps.optJSONArray(k) ?: return@forEach
                    val season = k.toIntOrNull() ?: 1
                    bySeason[season] = episodes(arr, season)
                }
                is JSONArray -> for (i in 0 until eps.length()) {
                    val arr = eps.optJSONArray(i) ?: continue
                    if (arr.length() == 0) continue
                    val season = arr.optJSONObject(0)?.optString("season")?.toIntOrNull() ?: (i + 1)
                    bySeason[season] = episodes(arr, season)
                }
            }
            val backdrops = info.opt("backdrop_path")
            val backdrop = (backdrops as? JSONArray)?.optString(0) ?: (backdrops as? String).orEmpty()
            SeriesInfo(info.optString("plot"), info.optString("cast"), info.optString("genre"),
                info.optString("releaseDate", info.optString("release_date")), info.optString("cover"), backdrop, bySeason,
                info.optString("tmdb").ifEmpty { info.optString("tmdb_id") })
        }.getOrNull()
    }

    private fun episodes(arr: JSONArray, season: Int): List<Episode> = (0 until arr.length()).mapNotNull { i ->
        val e = arr.optJSONObject(i) ?: return@mapNotNull null
        val num = e.optString("episode_num").toIntOrNull() ?: (i + 1)
        val title = e.optString("title").ifEmpty { "Episode $num" }
        val info = e.optJSONObject("info") ?: JSONObject()
        Episode(
            e.optString("id").ifEmpty { "$season-$num" }, e.optString("season").toIntOrNull() ?: season, num, title,
            XtreamFormatter.format(title).cleanTitle, e.optString("container_extension").ifEmpty { "mp4" },
            info.optString("movie_image"), info.optString("plot"), info.optString("duration_secs").toIntOrNull() ?: 0
        )
    }.sortedBy { it.episodeNum }

    suspend fun movieInfo(streamId: Int): MovieInfo? = withContext(Dispatchers.IO) {
        runCatching {
            val info = JSONObject(fetchText(apiUrl("get_vod_info", mapOf("vod_id" to streamId.toString())))).optJSONObject("info") ?: JSONObject()
            val backdrops = info.opt("backdrop_path")
            MovieInfo(info.optString("plot").ifEmpty { info.optString("description") }, info.optString("cast"), info.optString("director"),
                info.optString("genre"), info.optString("releasedate", info.optString("release_date")),
                info.optString("duration_secs").toIntOrNull() ?: 0,
                (backdrops as? JSONArray)?.optString(0) ?: (backdrops as? String).orEmpty(),
                info.optString("tmdb_id").ifEmpty { info.optString("tmdb") })
        }.getOrNull()
    }

    /** A channel's upcoming programmes (get_short_epg), or null when the request failed. */
    suspend fun shortEpg(streamId: Int, limit: Int): List<Programme>? = withContext(Dispatchers.IO) {
        runCatching {
            val arr = JSONObject(fetchText(apiUrl("get_short_epg", mapOf("stream_id" to streamId.toString(), "limit" to limit.toString()))))
                .optJSONArray("epg_listings") ?: JSONArray()
            (0 until arr.length()).mapNotNull { i ->
                val e = arr.optJSONObject(i) ?: return@mapNotNull null
                Programme(Programme.decode(e.optString("title")).ifBlank { "Programme" }, Programme.decode(e.optString("description")).trim(),
                    e.optString("start_timestamp").toLongOrNull() ?: 0, e.optString("stop_timestamp").toLongOrNull() ?: 0)
            }.sortedBy { it.start }
        }.getOrNull()
    }

    private fun fetchText(url: String): String {
        val conn = open(url)
        return try { conn.inputStream.bufferedReader().use { it.readText() } } finally { conn.disconnect() }
    }

    private fun open(url: String) = (URL(url).openConnection() as HttpURLConnection).apply {
        connectTimeout = 15_000
        readTimeout = 60_000
        setRequestProperty("User-Agent", USER_AGENT)
    }

    companion object {
        /** The same as the TV app's: some panels only answer known player apps. */
        const val USER_AGENT = "IPTVSmartersPlayer/3.0 (iOS; iPhone; Scale/3.00)"

        private fun sha1(s: String) = MessageDigest.getInstance("SHA-1").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }.take(16)

        /** One flat JSON object; nested arrays keep their first string (e.g. backdrop_path), objects are skipped. */
        private fun readObject(r: JsonReader): Map<String, Any?> {
            val m = HashMap<String, Any?>(24)
            r.beginObject()
            while (r.hasNext()) {
                val name = r.nextName()
                m[name] = when (r.peek()) {
                    JsonToken.STRING -> r.nextString()
                    JsonToken.NUMBER -> r.nextString()
                    JsonToken.BOOLEAN -> r.nextBoolean().toString()
                    JsonToken.NULL -> { r.nextNull(); null }
                    JsonToken.BEGIN_ARRAY -> {
                        var first: String? = null
                        r.beginArray()
                        while (r.hasNext()) { if (first == null && r.peek() == JsonToken.STRING) first = r.nextString() else r.skipValue() }
                        r.endArray()
                        first
                    }
                    else -> { r.skipValue(); null }
                }
            }
            r.endObject()
            return m
        }

        private fun Map<String, Any?>.str(key: String) = (this[key] as? String).orEmpty()
        private fun Map<String, Any?>.int(key: String) = (this[key] as? String)?.toDoubleOrNull()?.toInt() ?: 0
        private fun Map<String, Any?>.long(key: String) = (this[key] as? String)?.toDoubleOrNull()?.toLong() ?: 0L

        /** "7.5", or from rating_5based (x2) when the plain rating is missing. */
        private fun Map<String, Any?>.rating(): String {
            val r = str("rating").trim()
            if (r.isNotEmpty() && r != "0" && r != "0.0") return r
            val five = (this["rating_5based"] as? String)?.toDoubleOrNull() ?: 0.0
            return if (five > 0) "%.1f".format(five * 2) else ""
        }

        private fun liveChannel(o: Map<String, Any?>): LiveChannel {
            val name = o.str("name").ifEmpty { "Channel" }
            val f = XtreamFormatter.format(name)
            return LiveChannel(o.int("stream_id"), o.int("num"), name, f.cleanTitle, f.badges, o.str("stream_icon"),
                o.str("category_id"), o.str("is_adult") == "1", f.isSectionDivider)
        }

        private fun movie(o: Map<String, Any?>): Movie {
            val name = o.str("name").ifEmpty { "Movie" }
            val f = XtreamFormatter.format(name)
            return Movie(o.int("stream_id"), name, f.cleanTitle, f.badges, o.str("stream_icon"), o.rating(), o.long("added"),
                o.str("category_id"), o.str("container_extension").ifEmpty { "mp4" }, o.str("is_adult") == "1")
        }

        private fun series(o: Map<String, Any?>): Series {
            val name = o.str("name").ifEmpty { "Series" }
            val f = XtreamFormatter.format(name)
            val backdrop = o.str("backdrop_path")
            return Series(o.int("series_id"), name, f.cleanTitle, o.str("cover").ifEmpty { backdrop }, backdrop.ifEmpty { o.str("cover") },
                o.str("plot"), o.str("genre"), o.rating(), o.str("releaseDate").ifEmpty { o.str("release_date") },
                o.long("last_modified"), o.str("category_id"))
        }
    }
}
