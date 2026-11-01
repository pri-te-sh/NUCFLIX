package com.pritesh.nucflix.phone.data

import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.FirebaseFunctionsException
import kotlinx.coroutines.tasks.await

/**
 * The AI features' calls (Cloud Functions: Clef decisions, Gemma 4) and the markers they produce, shared with the
 * TV and iPhone apps. Every call may fail; the app then carries on as before.
 */
object SmartAI {
    private val functions get() = FirebaseFunctions.getInstance("us-central1")
    /** Out of AI budget, or the service refused us: stop asking until the app restarts. */
    var disabled = false; private set

    private suspend fun call(name: String, data: Map<String, Any?>): Map<String, Any?>? {
        if (disabled) return null
        return try {
            @Suppress("UNCHECKED_CAST")
            functions.getHttpsCallable(name).call(data).await().getData() as? Map<String, Any?>
        } catch (e: FirebaseFunctionsException) {
            if (e.code in setOf(FirebaseFunctionsException.Code.RESOURCE_EXHAUSTED, FirebaseFunctionsException.Code.PERMISSION_DENIED,
                    FirebaseFunctionsException.Code.UNAUTHENTICATED)) disabled = true
            null
        } catch (e: Exception) {
            null
        }
    }

    // ---------------------------------------------------------------- frame checks

    data class Verdict(val label: String, val confidence: Double, val probabilities: Map<String, Double>) {
        fun p(label: String) = probabilities[label] ?: 0.0
    }

    /** Clef's look at one or two frames (base64 JPEG): task "credits" or "live". */
    suspend fun frameCheck(task: String, images: List<String>, title: String?): Verdict? {
        val r = call("frameCheck", mapOf("task" to task, "images" to images, "title" to title?.take(200))) ?: return null
        @Suppress("UNCHECKED_CAST")
        val probs = (r["probabilities"] as? Map<String, Any?>).orEmpty().mapNotNull { (k, v) -> (v as? Number)?.let { k to it.toDouble() } }.toMap()
        return Verdict(r["label"] as? String ?: return null, (r["confidence"] as? Number)?.toDouble() ?: 0.0, probs)
    }

    // ---------------------------------------------------------------- markers (users/{uid}/markers/{lineId}:{kind}:{id})

    /** Where a title's credits start / intro ends (found once, shared by every device). kind: movie | episode | series. */
    data class Marker(val creditsAt: Double?, val introStart: Double?, val introEnd: Double?, val duration: Double?)

    suspend fun marker(uid: String, lineId: String, kind: String, id: String): Marker = runCatching {
        val d = FirebaseFirestore.getInstance().collection("users").document(uid).collection("markers").document("$lineId:$kind:$id").get().await()
        Marker(d.getDouble("creditsAt"), d.getDouble("introStart"), d.getDouble("introEnd"), d.getDouble("duration"))
    }.getOrDefault(Marker(null, null, null, null))

    fun saveMarker(uid: String, lineId: String, kind: String, id: String, duration: Double, fields: Map<String, Double>) {
        if (!duration.isFinite() || duration <= 0) return
        val doc = mutableMapOf<String, Any>("lineId" to lineId, "kind" to kind, "source" to "ai", "updatedAt" to FieldValue.serverTimestamp(),
            "duration" to Math.round(duration * 10) / 10.0)
        fields.forEach { (k, v) -> if (v.isFinite()) doc[k] = Math.round(v * 10) / 10.0 }
        FirebaseFirestore.getInstance().collection("users").document(uid).collection("markers").document("$lineId:$kind:$id").set(doc, SetOptions.merge())
    }

    // ---------------------------------------------------------------- smart search

    /** What Gemma read from a request like "funny hindi movies from the 2010s". */
    data class SearchFilters(
        val kind: String, val keywords: List<String>, val genres: List<String>, val languages: List<String>,
        val yearFrom: Int?, val yearTo: Int?, val sort: String
    ) {
        /** "Hindi comedy movies, 2010–2019" */
        fun describe(): String {
            val names = mapOf("en" to "English", "hi" to "Hindi", "ta" to "Tamil", "te" to "Telugu", "ml" to "Malayalam", "es" to "Spanish", "ar" to "Arabic", "fr" to "French")
            val noun = mapOf("movie" to "movies", "series" to "shows", "live" to "channels")[kind] ?: "titles"
            var text = listOf(languages.joinToString("/") { names[it] ?: it.uppercase() }, genres.joinToString("/"), noun).filter { it.isNotEmpty() }.joinToString(" ")
            text = text.replaceFirstChar { it.uppercase() }
            if (yearFrom != null && yearTo != null && yearFrom != yearTo) text += ", $yearFrom–$yearTo" else (yearFrom ?: yearTo)?.let { text += ", $it" }
            if (keywords.isNotEmpty()) text += " matching “${keywords.joinToString(" ")}”"
            return text
        }
    }

    private val searchCache = HashMap<String, SearchFilters>()

    /** Filters for a natural-language request (3+ words), or null for a plain title search / AI unavailable. */
    suspend fun searchFilters(query: String): SearchFilters? {
        val q = query.trim().lowercase()
        if (q.split(Regex("\\s+")).size < 3) return null
        searchCache[q]?.let { return it }
        val r = call("smartSearch", mapOf("query" to q)) ?: return null
        @Suppress("UNCHECKED_CAST")
        fun list(key: String) = (r[key] as? List<Any?>).orEmpty().mapNotNull { it as? String }
        return SearchFilters(r["kind"] as? String ?: "any", list("keywords"), list("genres"), list("languages"),
            (r["yearFrom"] as? Number)?.toInt(), (r["yearTo"] as? Number)?.toInt(), r["sort"] as? String ?: "relevance").also { searchCache[q] = it }
    }

    private val yearRe = Regex("\\((19|20)\\d{2}\\)|\\b(19|20)\\d{2}\\b")
    private fun yearOf(name: String) = yearRe.find(name)?.value?.filter { it.isDigit() }?.toIntOrNull()

    /** The catalog titles matching the filters (language and genre from the category tags, years from titles). */
    fun applyFilters(f: SearchFilters, cat: FilteredCatalog, tag: (Kind, String) -> CategoryTag?): List<Any> {
        data class Hit(val item: Any, val score: Double, val year: Int?, val added: Long, val rating: Double)
        val words = f.keywords.map { it.lowercase() }
        val out = ArrayList<Hit>()
        fun consider(kind: Kind, item: Any, name: String, categoryId: String, rating: String, added: Long) {
            val t = tag(kind, categoryId)
            if (f.languages.isNotEmpty() && (t == null || t.lang !in f.languages)) return
            val genreHit = t != null && t.genre in f.genres
            if (f.genres.isNotEmpty() && !genreHit && words.isEmpty()) return
            val year = yearOf(name)
            if (f.yearFrom != null && (year == null || year < f.yearFrom)) return
            if (f.yearTo != null && (year == null || year > f.yearTo)) return
            val lower = name.lowercase()
            val hits = words.count { lower.contains(it) }
            if (words.isNotEmpty() && hits == 0 && !(f.genres.isNotEmpty() && genreHit)) return
            val r = rating.toDoubleOrNull() ?: 0.0
            out += Hit(item, hits * 3 + (if (genreHit) 2 else 0) + r / 10, year, added, r)
        }
        if (f.kind == "any" || f.kind == "movie") cat.movies.forEach { consider(Kind.MOVIE, it, it.name, it.categoryId, it.rating, it.added) }
        if (f.kind == "any" || f.kind == "series") cat.series.forEach { consider(Kind.SERIES, it, it.name, it.categoryId, it.rating, it.lastModified) }
        if (f.kind == "any" || f.kind == "live") cat.live.forEach { consider(Kind.LIVE, it, it.name, it.categoryId, "", 0) }
        val sorted = when (f.sort) {
            "newest" -> out.sortedWith(compareByDescending<Hit> { it.year ?: 0 }.thenByDescending { it.added })
            "rating" -> out.sortedByDescending { it.rating }
            else -> out.sortedWith(compareByDescending<Hit> { it.score }.thenByDescending { it.added })
        }
        return sorted.take(60).map { it.item }
    }

    // ---------------------------------------------------------------- live channel alternatives

    private val quality = Regex("\\b(uhd|fhd|hd|sd|4k|8k|hevc|h265|backup|bk|raw|vip|plus|\\d{3,4}p|50fps|60fps)\\b", RegexOption.IGNORE_CASE)
    private fun channelKey(name: String) = name.lowercase().replace(Regex("^[a-z]{2,3}\\s*[|:\\-]\\s*"), "").replace(quality, " ")
        .replace(Regex("[^a-z0-9]+"), " ").trim()

    /** Other channels that look like the same station (another quality or source), best first. */
    fun alternatives(channel: LiveChannel, live: List<LiveChannel>): List<LiveChannel> {
        val key = channelKey(channel.cleanName)
        if (key.isEmpty()) return emptyList()
        return live.filter { it.streamId != channel.streamId && channelKey(it.cleanName) == key }.take(5)
    }
}
