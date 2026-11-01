package com.pritesh.nucflix.phone.data

import android.util.Base64
import androidx.compose.runtime.mutableStateMapOf
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.text.DateFormat
import java.util.Date

/** One programme in a channel's guide (the provider's short EPG). Times are epoch seconds. */
data class Programme(val title: String, val description: String, val start: Long, val stop: Long) {
    fun isNow(now: Long = System.currentTimeMillis() / 1000) = start <= now && stop > now

    fun progress(now: Long = System.currentTimeMillis() / 1000): Float =
        if (stop > start) ((now - start).toFloat() / (stop - start)).coerceIn(0f, 1f) else 0f

    /** "8:00 PM – 9:30 PM" in the phone's time format. */
    fun timeRange(): String {
        if (start <= 0 || stop <= 0) return ""
        val f = DateFormat.getTimeInstance(DateFormat.SHORT)
        return "${f.format(Date(start * 1000))} – ${f.format(Date(stop * 1000))}"
    }

    companion object {
        /** Providers send titles and descriptions base64-encoded (most of them): decoded when it's valid UTF-8 text. */
        fun decode(s: String): String {
            val t = s.trim()
            if (t.isEmpty() || t.length % 4 == 1) return s
            return runCatching {
                val bytes = Base64.decode(t, Base64.DEFAULT)
                Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString().takeIf { it.isNotBlank() && it.none { c -> c < ' ' && c != '\n' && c != '\r' && c != '\t' } }
            }.getOrNull() ?: s
        }
    }
}

/**
 * Channel guides, fetched one channel at a time as rows come into view (the same as the TV app: a few at once,
 * kept 5 minutes). Observable, so rows recompose when their guide arrives.
 */
class Epg(private val client: () -> XtreamClient?) {
    private class Entry(val at: Long, val list: List<Programme>)

    private val cache = mutableStateMapOf<Int, Entry>()
    private val inFlight = HashSet<Int>()
    private val gate = Semaphore(3)

    fun clear() { cache.clear(); inFlight.clear() }

    /** The cached guide (possibly empty: the channel publishes none), or null when not loaded yet. */
    fun listings(streamId: Int): List<Programme>? = cache[streamId]?.list

    /** What's on now (or the first listing when the times don't cover now). */
    fun now(streamId: Int): Programme? = cache[streamId]?.list?.let { l -> l.firstOrNull { it.isNow() } ?: l.firstOrNull() }

    suspend fun load(streamId: Int, force: Boolean = false) {
        val hit = cache[streamId]
        // Fresh for 5 minutes, but not past the end of the programme that was on.
        if (!force && hit != null && System.currentTimeMillis() - hit.at < 5 * 60_000 &&
            hit.list.firstOrNull { it.isNow() }?.let { it.stop * 1000 > System.currentTimeMillis() } != false) return
        if (!inFlight.add(streamId)) return
        try {
            val c = client() ?: return
            val list = gate.withPermit { c.shortEpg(streamId, 12) } ?: return
            if (client() === c) cache[streamId] = Entry(System.currentTimeMillis(), list)
        } finally {
            inFlight.remove(streamId)
        }
    }
}
