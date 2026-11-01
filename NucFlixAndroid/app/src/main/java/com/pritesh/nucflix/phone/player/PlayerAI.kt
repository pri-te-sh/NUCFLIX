package com.pritesh.nucflix.phone.player

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.PixelCopy
import android.view.SurfaceView
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.ui.PlayerView
import com.pritesh.nucflix.phone.data.SmartAI
import com.pritesh.nucflix.phone.data.Watching
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import java.io.ByteArrayOutputStream
import kotlin.coroutines.resume

/**
 * The player's AI checks, the same as the TV and iPhone apps: where the end credits start (saved and shared, so
 * each title is only searched once; a show's earlier episodes narrow the search), Skip Intro from saved markers,
 * and a one-time "is this live channel off air?" look. Each look is an AI call, so they're kept few.
 */
class PlayerAI(
    private val context: Context,
    private val scope: CoroutineScope,
    private val uid: String?,
    private val lineId: String?,
    private val frame: suspend () -> String?
) {
    var skipIntroTo by mutableStateOf<Double?>(null); private set
    /** "black" | "frozen" | "offline": the live channel looks off air. */
    var offAir by mutableStateOf<String?>(null)
    /** Set when the credits start (the player then counts down to the next episode). */
    var creditsReachedAt by mutableStateOf<Long?>(null); private set

    private var request: PlayRequest? = null
    private var ref: Pair<String, String>? = null // (kind, id) of the marker
    private var marker: SmartAI.Marker? = null
    private var creditsHint: Double? = null // seconds from the end where this show's credits started before
    private var creditsHit: Double? = null
    private var busy = false
    private var nextCheckAt = 0L
    private var lastPos: Triple<Double, Long, Boolean>? = null
    private var pass = 0
    private var liveDone = false
    private var playingSince = 0L
    private var generation = 0

    fun start(req: PlayRequest) {
        generation++
        request = req
        marker = null; creditsHint = null; creditsHit = null; creditsReachedAt = null
        skipIntroTo = null; offAir = null; busy = false; nextCheckAt = 0; lastPos = null; liveDone = false; playingSince = 0
        val w = req.watching
        ref = when (w) { is Watching.MovieItem -> "movie" to w.streamId.toString(); is Watching.EpisodeItem -> "episode" to w.episodeId; else -> null }
        val (kind, id) = ref ?: return
        if (uid == null || lineId == null) return
        val gen = generation
        scope.launch {
            val m = SmartAI.marker(uid, lineId, kind, id)
            // A new episode: where the show's credits started last time narrows the search to a few looks.
            if (w is Watching.EpisodeItem && m.creditsAt == null) {
                val s = SmartAI.marker(uid, lineId, "series", w.seriesId.toString())
                val fromEnd = (s.duration ?: 0.0) - (s.creditsAt ?: 0.0)
                if (gen == generation && s.creditsAt != null && fromEnd > 5 && fromEnd < 900) creditsHint = fromEnd
            }
            if (gen == generation) marker = m
        }
    }

    fun stop() { generation++; request = null }

    /** Past the detected start of the credits (progress then saves as finished). */
    fun pastCredits(pos: Double) = marker?.creditsAt?.let { it > 0 && pos >= it } == true

    /** Called every second with the player's position. */
    fun tick(pos: Double, dur: Double, playing: Boolean, isLive: Boolean, title: String) {
        val req = request ?: return
        if (isLive) { liveTick(playing, title); return }
        val m = marker ?: return
        if (dur <= 0) return
        watchForSeeks(pos, playing)
        if (creditsReachedAt == null) {
            val at = m.creditsAt
            if (at != null && at > 0) { if (pos >= at && pos < dur - 2) creditsReachedAt = System.currentTimeMillis() }
            else if (dur > 300 && playing && pos >= creditsFrom(dur, req)) check(pos, dur, title)
        }
        skipIntroTo = m.introEnd?.let { end ->
            val from = m.introStart ?: 0.0
            if (end > from + 5 && pos >= from - 1 && pos < end - 3) end else null
        }
    }

    /** Where the credits search starts: just before this show's usual spot, else the last stretch of the title. */
    private fun creditsFrom(dur: Double, req: PlayRequest): Double {
        creditsHint?.let { return maxOf(dur * 0.5, dur - it - 45) }
        return if (req.watching is Watching.MovieItem) maxOf(dur * 0.85, dur - 600) else maxOf(dur * 0.8, dur - 600)
    }

    /** Gap between looks: tight around the show's usual spot, sparse elsewhere (each look is an AI call). */
    private fun step(pos: Double, dur: Double): Long {
        creditsHint?.let { if (pos <= dur - it + 60) return 8_000 }
        return if (request?.watching is Watching.MovieItem) 30_000 else 15_000
    }

    /** A jump (scrubbing, resume) breaks the run of frames the evidence was built on: start over. */
    private fun watchForSeeks(pos: Double, playing: Boolean) {
        val prev = lastPos
        val now = System.currentTimeMillis()
        lastPos = Triple(pos, now, playing)
        if (prev == null) return
        val ran = if (prev.third) (now - prev.second) / 1000.0 else 0.0
        if (pos > prev.first - 3 && pos < prev.first + ran + 8) return
        pass++
        creditsHit = null
        nextCheckAt = now + 2_000 // look again once the picture has settled
    }

    private fun check(pos: Double, dur: Double, title: String) {
        if (busy || System.currentTimeMillis() < nextCheckAt || SmartAI.disabled) return
        busy = true
        nextCheckAt = System.currentTimeMillis() + step(pos, dur)
        val gen = generation
        val p = pass
        scope.launch {
            try {
                val f = frame() ?: return@launch
                val r = SmartAI.frameCheck("credits", listOf(f), title) ?: return@launch
                if (gen != generation || p != pass) return@launch // the picture moved on meanwhile
                val credits = r.p("end_credits") + r.p("next_preview")
                if (credits < 0.7) { creditsHit = null; return@launch }
                val hit = creditsHit ?: pos
                if (creditsHit == null && credits < 0.92) { creditsHit = pos; nextCheckAt = System.currentTimeMillis() + 3_000; return@launch } // confirm
                marker = marker?.copy(creditsAt = hit)
                val (kind, id) = ref ?: return@launch
                if (uid != null && lineId != null) {
                    SmartAI.saveMarker(uid, lineId, kind, id, dur, mapOf("creditsAt" to hit))
                    // Remembered for the show too, so its other episodes only look near the same spot.
                    (request?.watching as? Watching.EpisodeItem)?.let { SmartAI.saveMarker(uid, lineId, "series", it.seriesId.toString(), dur, mapOf("creditsAt" to hit)) }
                }
                creditsReachedAt = System.currentTimeMillis()
            } finally {
                busy = false
            }
        }
    }

    // ---------------------------------------------------------------- live channels

    private fun liveTick(playing: Boolean, title: String) {
        if (liveDone) return
        if (!playing) { playingSince = 0; return }
        if (playingSince == 0L) { playingSince = System.currentTimeMillis(); return }
        if (System.currentTimeMillis() - playingSince < 10_000 || busy || SmartAI.disabled) return
        liveDone = true
        val channel = (request?.watching as? Watching.LiveItem)?.streamId?.toString() ?: return
        // A channel that looked fine recently isn't checked again (flicking through channels was an AI call each).
        val prefs = context.getSharedPreferences("nucflix.liveOk", Context.MODE_PRIVATE)
        if (System.currentTimeMillis() - prefs.getLong(channel, 0) < 6 * 3600_000L) return
        busy = true
        val gen = generation
        scope.launch {
            try {
                val a = frame() ?: return@launch
                delay(3_000)
                val b = frame() ?: return@launch
                val r = SmartAI.frameCheck("live", listOf(a, b), title) ?: return@launch
                if (gen != generation) return@launch
                if (r.label != "ok" && r.p(r.label) >= 0.7 && r.confidence >= 0.5) { offAir = r.label; return@launch }
                prefs.edit().putLong(channel, System.currentTimeMillis()).apply()
                if (prefs.all.size > 300) { // keep the newest few hundred
                    prefs.all.entries.sortedBy { it.value as? Long ?: 0 }.take(prefs.all.size - 300).let { old -> prefs.edit().apply { old.forEach { remove(it.key) } }.apply() }
                }
            } finally {
                busy = false
            }
        }
    }

    companion object {
        /** The picture on screen as a ~512 px (or [width]) JPEG (base64), copied from the player's surface. */
        suspend fun grab(view: PlayerView?, width: Int = 512): String? {
            val surface = view?.videoSurfaceView as? SurfaceView ?: return null
            if (surface.width <= 0 || surface.height <= 0) return null
            val w = width
            val h = (w * surface.height / surface.width).coerceAtLeast(1)
            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val ok = suspendCancellableCoroutine { cont ->
                runCatching {
                    PixelCopy.request(surface, bitmap, { result -> cont.resume(result == PixelCopy.SUCCESS) }, Handler(Looper.getMainLooper()))
                }.onFailure { cont.resume(false) }
            }
            if (!ok) return null
            // Encoding takes tens of milliseconds (more for X-Ray's bigger frame): off the main thread.
            return withContext(Dispatchers.Default) {
                val out = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.JPEG, 72, out)
                bitmap.recycle()
                Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
            }
        }
    }
}
