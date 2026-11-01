package com.pritesh.nucflix.phone.data

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * A downloaded (or queued) title. No stream URL is kept: it carries the login, so it's rebuilt from the line
 * when the download runs.
 */
data class DownloadItem(
    val id: String,            // "movie:123" / "episode:4567"
    val lineId: String,
    val kind: String,          // "movie" | "episode"
    val title: String,
    val subtitle: String?,
    val artwork: String?,
    val streamId: Int?,
    val seriesId: Int?,
    val episodeId: String?,
    val season: Int?,
    val episode: Int?,
    val ext: String,
    val state: State,
    val bytes: Long = 0,
    val total: Long = 0,
    val completedAt: Long = 0,
    val error: String? = null
) {
    enum class State { QUEUED, DOWNLOADING, WAITING_FOR_LINE, PAUSED, DONE, FAILED }

    val fraction: Float get() = if (total > 0) (bytes.toFloat() / total).coerceIn(0f, 1f) else 0f

    fun toJson() = JSONObject().apply {
        put("id", id); put("lineId", lineId); put("kind", kind); put("title", title); put("subtitle", subtitle); put("artwork", artwork)
        put("streamId", streamId); put("seriesId", seriesId); put("episodeId", episodeId); put("season", season); put("episode", episode)
        put("ext", ext); put("state", state.name); put("bytes", bytes); put("total", total); put("completedAt", completedAt); put("error", error)
    }

    companion object {
        fun from(o: JSONObject) = DownloadItem(
            o.getString("id"), o.getString("lineId"), o.getString("kind"), o.getString("title"), o.optString("subtitle").ifEmpty { null },
            o.optString("artwork").ifEmpty { null }, o.optInt("streamId", -1).takeIf { it >= 0 }, o.optInt("seriesId", -1).takeIf { it >= 0 },
            o.optString("episodeId").ifEmpty { null }, o.optInt("season", -1).takeIf { it >= 0 }, o.optInt("episode", -1).takeIf { it >= 0 },
            o.optString("ext", "mp4"),
            // A download that was running when the app stopped carries on from where its file ends.
            State.valueOf(o.optString("state", "QUEUED")).let { if (it == State.DOWNLOADING || it == State.WAITING_FOR_LINE) State.QUEUED else it },
            o.optLong("bytes"), o.optLong("total"), o.optLong("completedAt"), o.optString("error").ifEmpty { null }
        )
    }
}

/**
 * Downloads to the app's own storage, one at a time, in pieces. Before each piece it checks the line: IPTV lines
 * often allow one connection, so while anyone in the household streams from it (their "now playing" presence),
 * downloads wait and carry on afterwards. Same rules as the iPhone app.
 */
class DownloadManager(private val context: Context) {
    private val prefs = context.getSharedPreferences("nucflix.downloads", Context.MODE_PRIVATE)
    var items by mutableStateOf(emptyList<DownloadItem>()); private set
    /** Names of the devices streaming from the line right now (downloads wait for them). */
    var watching by mutableStateOf(emptyList<String>()); private set
    /** Smart downloads: delete an episode once it's been watched (default on, as on the iPhone). */
    var deleteWatched by mutableStateOf(prefs.getBoolean("deleteWatched", true)); private set

    fun changeDeleteWatched(on: Boolean) {
        deleteWatched = on
        prefs.edit().putBoolean("deleteWatched", on).apply()
    }

    private val dir = File(context.filesDir, "downloads").apply { mkdirs() }
    private val index = File(dir, "index.json")
    private var presence: ListenerRegistration? = null
    private var presenceKey: String? = null
    private var devices: List<DocumentSnapshot> = emptyList()

    /** Set by the app: the line logins (to build URLs), this phone's own presence id, and whether it streams now. */
    var lines: () -> List<CloudLine> = { emptyList() }
    var deviceId: String = ""
    var streamingHere: () -> String? = { null } // the line this phone streams from, if any
    /** Connections the provider allows per line (from its login answer); unknown lines count as 1. */
    val maxConnections = HashMap<String, Int>()

    init {
        items = runCatching { JSONArray(index.readText()).let { a -> (0 until a.length()).map { DownloadItem.from(a.getJSONObject(it)) } } }.getOrDefault(emptyList())
    }

    fun item(id: String) = items.firstOrNull { it.id == id }
    fun fileFor(item: DownloadItem) = File(dir, item.id.replace(':', '_') + "." + item.ext.ifEmpty { "mp4" })
    private fun partFor(item: DownloadItem) = File(dir, item.id.replace(':', '_') + ".part")

    /** The local file for a finished download (to play offline), or null. */
    fun localFile(id: String): File? = item(id)?.takeIf { it.state == DownloadItem.State.DONE }?.let(::fileFor)?.takeIf { it.exists() }

    fun enqueue(item: DownloadItem) {
        if (item(item.id) != null) return
        update(items + item.copy(state = DownloadItem.State.QUEUED))
        startService()
    }

    /** Restarts the queue (e.g. after the app was closed mid-download). */
    fun resumeAll() { if (hasWork()) startService() }

    fun pause(id: String) = edit(id) { it.copy(state = DownloadItem.State.PAUSED) }
    fun resume(id: String) { edit(id) { it.copy(state = DownloadItem.State.QUEUED, error = null) }; startService() }

    fun remove(id: String) {
        item(id)?.let { fileFor(it).delete(); partFor(it).delete() }
        update(items.filterNot { it.id == id })
    }

    /** Smart downloads: episodes downloaded and then watched (on any device) go, to free space. */
    fun removeWatched(progress: List<Progress>) {
        if (!deleteWatched) return
        items.filter { it.kind == "episode" && it.state == DownloadItem.State.DONE }.forEach { d ->
            val p = progress.firstOrNull { it.kind == "episode" && it.episodeId == d.episodeId } ?: return@forEach
            if (p.isWatched && p.updatedAt > d.completedAt) remove(d.id)
        }
    }

    fun hasWork() = items.any { it.state == DownloadItem.State.QUEUED || it.state == DownloadItem.State.DOWNLOADING || it.state == DownloadItem.State.WAITING_FOR_LINE }

    private fun startService() {
        // Android 12+ refuses foreground services started from the background; the queue then resumes next launch.
        runCatching { ContextCompat.startForegroundService(context, Intent(context, com.pritesh.nucflix.phone.DownloadService::class.java)) }
    }

    @Synchronized
    private fun update(list: List<DownloadItem>) {
        items = list
        runCatching { index.writeText(JSONArray(list.map { it.toJson() }).toString()) }
    }

    @Synchronized
    private fun edit(id: String, change: (DownloadItem) -> DownloadItem) = update(items.map { if (it.id == id) change(it) else it })

    // ---------------------------------------------------------------- line presence

    /** Follows the household's devices (for whether the line is in use). */
    fun watchPresence(uid: String?) {
        if (uid == presenceKey) return
        presence?.remove()
        presence = null
        presenceKey = uid
        if (uid == null) return
        presence = FirebaseFirestore.getInstance().collection("users").document(uid).collection("devices").addSnapshotListener { snap, _ ->
            devices = snap?.documents.orEmpty()
            watching = streamsOn(null)
        }
    }

    /** Devices streaming from [lineId] (any line when null), this phone included, seen in the last 150 s. */
    private fun streamsOn(lineId: String?): List<String> {
        val now = System.currentTimeMillis()
        val others = devices.filter { d ->
            if (d.id == deviceId) return@filter false
            @Suppress("UNCHECKED_CAST") val np = d.get("nowPlaying") as? Map<String, Any?> ?: return@filter false
            val seen = d.getTimestamp("lastSeen", DocumentSnapshot.ServerTimestampBehavior.ESTIMATE)?.toDate()?.time ?: 0
            (lineId == null || np["lineId"] == lineId) && now - seen < 150_000
        }.map { it.getString("name") ?: "Another device" }
        val here = streamingHere()
        return if (here != null && (lineId == null || here == lineId)) others + "This phone" else others
    }

    /** A free connection on the line for a download (streams always come first). */
    private fun lineFree(lineId: String) = streamsOn(lineId).size < (maxConnections[lineId] ?: 1)

    // ---------------------------------------------------------------- the download loop (run by DownloadService)

    /** Downloads queued items until there's nothing left to do (or only items waiting for the user). */
    suspend fun run(onProgress: (DownloadItem?) -> Unit) {
        var waitedForLines = 0
        while (true) {
            val next = items.firstOrNull { it.state == DownloadItem.State.QUEUED || it.state == DownloadItem.State.WAITING_FOR_LINE } ?: break
            if (lines().isEmpty()) {
                // Not signed in / lines not loaded yet (the app just started): wait a little, then leave it queued.
                if (++waitedForLines > 40) break
                delay(3000)
                continue
            }
            val line = lines().firstOrNull { it.id == next.lineId }
            if (line == null) { edit(next.id) { it.copy(state = DownloadItem.State.FAILED, error = "Its IPTV line was removed.") }; continue }
            if (!lineFree(line.id)) {
                edit(next.id) { it.copy(state = DownloadItem.State.WAITING_FOR_LINE) }
                onProgress(item(next.id))
                delay(15_000)
                continue
            }
            edit(next.id) { it.copy(state = DownloadItem.State.DOWNLOADING, error = null) }
            onProgress(item(next.id))
            val result = runCatching { downloadPiece(line, next.id) }
            val now = item(next.id) ?: continue // removed meanwhile
            result.onSuccess { finished ->
                retries.remove(now.id)
                if (finished) {
                    partFor(now).renameTo(fileFor(now))
                    edit(now.id) { it.copy(state = DownloadItem.State.DONE, bytes = it.total, completedAt = System.currentTimeMillis()) }
                } else if (now.state == DownloadItem.State.DOWNLOADING) {
                    edit(now.id) { it.copy(state = DownloadItem.State.QUEUED) } // next piece (after re-checking the line)
                }
            }.onFailure { e ->
                android.util.Log.w("NucFlixDownloads", "${now.id} at ${now.bytes}/${now.total}: $e")
                val busy = e is BusyLine
                // A dropped connection is retried a few times, later and later (as on the iPhone), before giving up.
                val tries = (retries[now.id] ?: 0) + 1
                val retry = !busy && e is java.io.IOException && tries <= RETRY_DELAYS.size
                if (retry) retries[now.id] = tries else retries.remove(now.id)
                edit(now.id) {
                    when {
                        busy -> it.copy(state = DownloadItem.State.WAITING_FOR_LINE)
                        retry -> it.copy(state = DownloadItem.State.QUEUED)
                        else -> it.copy(state = DownloadItem.State.FAILED,
                            error = if (e is java.io.IOException) "The connection kept dropping. Tap to try again." else e.message ?: "Download failed.")
                    }
                }
                if (busy) delay(15_000) else if (retry) delay(RETRY_DELAYS[tries - 1])
            }
            onProgress(item(next.id))
        }
        onProgress(null)
    }

    private class BusyLine : Exception("The line is busy.")
    private val retries = HashMap<String, Int>()

    /** Downloads up to one piece; true once the whole file is there. */
    private suspend fun downloadPiece(line: CloudLine, id: String): Boolean = withContext(Dispatchers.IO) {
        val d = item(id) ?: return@withContext true
        val client = XtreamClient(line, context.cacheDir)
        val url = if (d.kind == "movie") client.movieUrl(d.streamId ?: 0, d.ext) else client.episodeUrl(d.episodeId ?: "", d.ext)
        val part = partFor(d)
        val offset = if (part.exists()) part.length() else 0L
        if (d.total > 0 && offset >= d.total) return@withContext true
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 30_000
            setRequestProperty("User-Agent", XtreamClient.USER_AGENT)
            setRequestProperty("Range", "bytes=$offset-${offset + PIECE - 1}")
        }
        try {
            val code = conn.responseCode
            // Providers' "no free connection" answers (and rate limiting): wait, don't fail.
            if (code in setOf(403, 429, 458, 503, 509, 884)) throw BusyLine()
            if (code !in 200..299) throw Exception("The provider answered $code.")
            val total = conn.getHeaderField("Content-Range")?.substringAfter('/')?.toLongOrNull()
                ?: if (code == 200) conn.contentLengthLong.takeIf { it > 0 } else null
            // A 200 means the server ignored the range: start over from the beginning.
            val append = code == 206 && offset > 0
            var written = if (append) offset else 0L
            conn.inputStream.use { input ->
                FileOutputStream(part, append).use { out ->
                    val buf = ByteArray(256 * 1024)
                    var sinceUpdate = 0L
                    while (true) {
                        val cur = item(id)
                        if (cur == null || cur.state != DownloadItem.State.DOWNLOADING) return@withContext false // paused / removed
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        written += n
                        sinceUpdate += n
                        if (sinceUpdate >= 2 * 1024 * 1024) { sinceUpdate = 0; edit(id) { it.copy(bytes = written, total = total ?: it.total) } }
                    }
                }
            }
            edit(id) { it.copy(bytes = written, total = total ?: written) }
            val size = total ?: written
            written >= size
        } finally {
            conn.disconnect()
        }
    }

    companion object {
        /** Between pieces the line is re-checked, so a stream that starts gets the connection within a piece. */
        const val PIECE = 32L * 1024 * 1024
        private val RETRY_DELAYS = longArrayOf(2_000, 5_000, 15_000, 30_000, 60_000)
    }
}
