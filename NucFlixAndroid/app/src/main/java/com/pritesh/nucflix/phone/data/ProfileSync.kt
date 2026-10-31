package com.pritesh.nucflix.phone.data

import android.os.Build
import com.google.firebase.firestore.DocumentSnapshot
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.Query
import com.google.firebase.firestore.DocumentSnapshot.ServerTimestampBehavior
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** A watch-progress document (users/{uid}/profiles/{pid}/progress/{lineId}:{kind}:{id}), as the other apps write it. */
data class Progress(
    val key: String, val kind: String, val title: String, val position: Double, val duration: Double, val updatedAt: Long,
    val streamId: Int?, val seriesId: Int?, val episodeId: String?, val season: Int?, val episode: Int?,
    val subtitle: String?, val artwork: String?, val ext: String?
) {
    /** Finished: 92% through or into the last 90 s (people stop during the credits). Same rule as the other apps. */
    val isWatched: Boolean get() = duration >= 60 && (position / duration >= 0.92 || duration - position <= 90)
    val resumeAt: Double get() = if (duration >= 60 && position > 20 && !isWatched) position else 0.0
}

/** A My List entry. */
data class Favorite(val kind: Kind, val id: Int, val title: String, val addedAt: Long)

/** What to write when the player reports a position. */
sealed interface Watching {
    val title: String
    val artwork: String?
    data class MovieItem(val streamId: Int, override val title: String, override val artwork: String?, val ext: String?) : Watching
    data class EpisodeItem(
        val seriesId: Int, val episodeId: String, val season: Int, val episode: Int, val episodeTitle: String,
        override val title: String, override val artwork: String?, val ext: String?
    ) : Watching
    data class LiveItem(val streamId: Int, override val title: String, override val artwork: String?) : Watching
}

/**
 * My List, watch progress and "now playing" presence for the active profile + line, live from Firestore.
 * Only the line's documents are queried (index: firebase/firestore.indexes.json).
 */
class ProfileSync(
    private val uid: String, private val profileId: String, private val lineId: String, private val deviceId: String,
    private val deviceName: String, private val onChange: () -> Unit
) {
    private val db = FirebaseFirestore.getInstance()
    private val profile = db.collection("users").document(uid).collection("profiles").document(profileId)
    private val listeners = mutableListOf<ListenerRegistration>()
    private val scope = MainScope()

    var favorites: List<Favorite> = emptyList(); private set
    var progress: List<Progress> = emptyList(); private set
    var loaded = false; private set
    private var favLoaded = false
    private var progLoaded = false

    // Progress writes are throttled per title; positions not written yet are flushed on pause / exit.
    private val pending = HashMap<String, Map<String, Any?>>()
    private val lastWrite = HashMap<String, Long>()
    private var flushJob: Job? = null

    fun start() {
        listeners += profile.collection("favorites").whereEqualTo("lineId", lineId).addSnapshotListener { snap, _ ->
            snap ?: return@addSnapshotListener
            favorites = snap.documents.mapNotNull(::favorite).sortedByDescending { it.addedAt }
            favLoaded = true
            loaded = favLoaded && progLoaded
            onChange()
        }
        listeners += profile.collection("progress").whereEqualTo("lineId", lineId)
            .orderBy("updatedAt", Query.Direction.DESCENDING).limit(150)
            .addSnapshotListener { snap, _ ->
                snap ?: return@addSnapshotListener
                progress = snap.documents.mapNotNull(::progressDoc)
                progLoaded = true
                loaded = favLoaded && progLoaded
                onChange()
            }
    }

    fun stop() {
        flush()
        setNowPlaying(null)
        listeners.forEach { it.remove() }
        listeners.clear()
    }

    // ---------------------------------------------------------------- My List

    fun isFavorite(kind: Kind, id: Int) = favorites.any { it.kind == kind && it.id == id }

    fun setFavorite(kind: Kind, id: Int, title: String, artwork: String?, ext: String?, categoryId: String?, on: Boolean) {
        val ref = profile.collection("favorites").document("$lineId:${kind.key}:$id")
        if (!on) { ref.delete(); return }
        val doc = mutableMapOf<String, Any>("lineId" to lineId, "kind" to kind.key, "id" to id, "title" to title.take(300).ifEmpty { "Untitled" },
            "addedAt" to FieldValue.serverTimestamp())
        artwork?.takeIf { it.isNotEmpty() && it.length <= 1000 }?.let { doc["artwork"] = it }
        ext?.takeIf { it.isNotEmpty() }?.let { doc["ext"] = it.take(10) }
        categoryId?.takeIf { it.isNotEmpty() }?.let { doc["categoryId"] = it.take(40) }
        ref.set(doc)
    }

    // ---------------------------------------------------------------- progress

    /** Records a position (written at most every PROGRESS_INTERVAL per title; `now` writes at once). */
    fun saveProgress(w: Watching, position: Double, duration: Double, now: Boolean = false) {
        val (kind, id) = when (w) {
            is Watching.MovieItem -> "movie" to w.streamId.toString()
            is Watching.EpisodeItem -> "episode" to w.episodeId
            is Watching.LiveItem -> "live" to w.streamId.toString()
        }
        val key = "$lineId:$kind:$id"
        val doc = mutableMapOf<String, Any?>(
            "lineId" to lineId, "kind" to kind, "title" to w.title.take(300).ifEmpty { "Untitled" },
            "position" to position.coerceAtLeast(0.0), "duration" to duration.coerceAtLeast(0.0),
            "updatedAt" to FieldValue.serverTimestamp(), "device" to deviceName.take(80)
        )
        when (w) {
            is Watching.MovieItem -> { doc["streamId"] = w.streamId; w.ext?.let { doc["ext"] = it.take(10) } }
            is Watching.LiveItem -> doc["streamId"] = w.streamId
            is Watching.EpisodeItem -> {
                doc["seriesId"] = w.seriesId; doc["episodeId"] = w.episodeId; doc["season"] = w.season; doc["episode"] = w.episode
                doc["subtitle"] = ("S${w.season} E${w.episode}" + if (w.episodeTitle.isNotEmpty()) " • ${w.episodeTitle}" else "").take(300)
                w.ext?.let { doc["ext"] = it.take(10) }
            }
        }
        w.artwork?.takeIf { it.isNotEmpty() && it.length <= 1000 }?.let { doc["artwork"] = it }
        pending[key] = doc
        if (now || System.currentTimeMillis() - (lastWrite[key] ?: 0) >= PROGRESS_INTERVAL) write(key)
        else if (flushJob == null) flushJob = scope.launch { delay(PROGRESS_INTERVAL); flushJob = null; flush() }
    }

    fun flush() {
        flushJob?.cancel()
        flushJob = null
        pending.keys.toList().forEach(::write)
    }

    private fun write(key: String) {
        val doc = pending.remove(key) ?: return
        lastWrite[key] = System.currentTimeMillis()
        profile.collection("progress").document(key).set(doc)
    }

    /** Forgets titles (Continue Watching removal): their progress documents go on every device. */
    fun deleteProgress(keys: Collection<String>) {
        if (keys.isEmpty()) return
        val batch = db.batch()
        keys.forEach { pending.remove(it); batch.delete(profile.collection("progress").document(it)) }
        batch.commit()
    }

    // ---------------------------------------------------------------- now playing

    // users/{uid}/devices/{deviceId}: while this phone streams from the line, other phones pause their downloads
    // (lines often allow one connection). lastSeen is refreshed every minute, so a phone that dies stops counting.
    private var nowPlaying: Map<String, Any>? = null
    private var presenceJob: Job? = null

    fun setNowPlaying(title: String?, kind: String? = null) {
        val was = nowPlaying != null
        nowPlaying = title?.let { mapOf("lineId" to lineId, "kind" to (kind ?: "movie"), "title" to it.take(200)) }
        presenceJob?.cancel()
        presenceJob = null
        if (nowPlaying != null) presenceJob = scope.launch { while (true) { delay(60_000); writePresence() } }
        if (nowPlaying != null || was) writePresence()
    }

    private fun writePresence() {
        db.collection("users").document(uid).collection("devices").document(deviceId).set(
            mapOf("name" to deviceName.take(80), "platform" to "android", "lastSeen" to FieldValue.serverTimestamp(), "nowPlaying" to nowPlaying)
        )
    }

    // ---------------------------------------------------------------- documents

    private fun favorite(d: DocumentSnapshot): Favorite? {
        val kind = Kind.entries.firstOrNull { it.key == d.getString("kind") } ?: return null
        val id = when (val raw = d.get("id")) { is Number -> raw.toInt(); is String -> raw.toIntOrNull(); else -> null } ?: return null
        return Favorite(kind, id, d.getString("title").orEmpty(),
            d.getTimestamp("addedAt", ServerTimestampBehavior.ESTIMATE)?.toDate()?.time ?: 0)
    }

    private fun progressDoc(d: DocumentSnapshot): Progress? {
        val kind = d.getString("kind") ?: return null
        return Progress(
            d.id, kind, d.getString("title").orEmpty(), d.getDouble("position") ?: 0.0, d.getDouble("duration") ?: 0.0,
            d.getTimestamp("updatedAt", ServerTimestampBehavior.ESTIMATE)?.toDate()?.time ?: System.currentTimeMillis(),
            d.getLong("streamId")?.toInt(), d.getLong("seriesId")?.toInt(), d.get("episodeId")?.toString(),
            d.getLong("season")?.toInt(), d.getLong("episode")?.toInt(), d.getString("subtitle"), d.getString("artwork"), d.getString("ext")
        )
    }

    companion object {
        const val PROGRESS_INTERVAL = 20_000L
        fun deviceName(): String = listOf(Build.MANUFACTURER.replaceFirstChar { it.uppercase() }, Build.MODEL).distinct().joinToString(" ").take(80)
    }
}
