package com.pritesh.nucflix.phone.data

import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.functions.FirebaseFunctions
import com.google.firebase.functions.FirebaseFunctionsException
import kotlinx.coroutines.delay
import kotlinx.coroutines.tasks.await

/** An AI category tag (users/{uid}/lineTags/{lineId}, written by the classifyCategories function). */
data class CategoryTag(val kids: Double, val adult: Double, val lang: String?, val genre: String?)

/**
 * The shared AI data for a line: category tags and kids-suitability title scores (both written by Cloud
 * Functions), plus filling in what's missing in the background. Same documents as the TV and iPhone apps.
 */
class SmartData(private val uid: String, private val lineId: String, private val onChange: () -> Unit) {
    private val db = FirebaseFirestore.getInstance()
    private val functions = FirebaseFunctions.getInstance("us-central1")
    private val listeners = mutableListOf<ListenerRegistration>()

    var tags: Map<String, CategoryTag> = emptyMap(); private set
    private val kidsShards = arrayOfNulls<Map<String, Double>>(KIDS_SHARDS)
    var kidsScores: Map<String, Double> = emptyMap(); private set
    /** Out of AI budget, or the service refused: stop asking until the next session. */
    private var disabled = false
    private var fillingTags = false
    private var fillingKids = false

    fun tag(kind: Kind, categoryId: String): CategoryTag? = tags["${kind.key}:$categoryId"]
    fun kidsScore(kind: Kind, id: Int): Double? = kidsScores["${kind.key}:$id"]

    fun start(watchKids: Boolean) {
        val user = db.collection("users").document(uid)
        @Suppress("UNCHECKED_CAST")
        listeners += user.collection("lineTags").document(lineId).addSnapshotListener { snap, _ ->
            val cats = snap?.get("cats") as? Map<String, Map<String, Any?>> ?: emptyMap()
            tags = cats.mapValues { (_, t) ->
                CategoryTag((t["kids"] as? Number)?.toDouble() ?: 0.5, (t["adult"] as? Number)?.toDouble() ?: 0.0,
                    t["lang"] as? String, t["genre"] as? String)
            }
            onChange()
        }
        if (!watchKids) return
        for (i in 0 until KIDS_SHARDS) {
            @Suppress("UNCHECKED_CAST")
            listeners += user.collection("kidsTitles").document("${lineId}_$i").addSnapshotListener { snap, _ ->
                kidsShards[i] = (snap?.get("titles") as? Map<String, Any?>).orEmpty().mapNotNull { (k, v) -> (v as? Number)?.let { k to it.toDouble() } }.toMap()
                kidsScores = kidsShards.filterNotNull().fold(HashMap()) { acc, m -> acc.putAll(m); acc }
                onChange()
            }
        }
    }

    fun stop() {
        listeners.forEach { it.remove() }
        listeners.clear()
    }

    /** Tags categories that have none yet, 16 per call, gently. */
    suspend fun fillTags(categories: List<Pair<Kind, Category>>) {
        if (fillingTags || disabled) return
        val todo = categories.filter { (k, c) -> tags["${k.key}:${c.id}"] == null && c.name.isNotBlank() }
        if (todo.isEmpty()) return
        fillingTags = true
        try {
            for (batch in todo.chunked(16)) {
                val items = batch.map { (k, c) -> mapOf("id" to c.id, "name" to c.name.take(120), "kind" to k.key) }
                if (call("classifyCategories", mapOf("lineId" to lineId, "categories" to items)) == null) break
                delay(1500)
            }
        } finally {
            fillingTags = false
        }
    }

    /** Scores titles that passed the kids rules but have no AI score yet, 40 per call, one shard per call. */
    suspend fun fillKids(pending: () -> List<Triple<Kind, Int, String>>) {
        if (fillingKids || disabled) return
        fillingKids = true
        try {
            repeat(400) {
                val todo = pending().filter { (k, id, _) -> kidsScores["${k.key}:$id"] == null }
                if (todo.isEmpty()) return
                val shard = todo.first().second % KIDS_SHARDS
                val batch = todo.filter { it.second % KIDS_SHARDS == shard }.take(40)
                val items = batch.map { (k, id, title) -> mapOf("kind" to k.key, "id" to id, "title" to title.take(160)) }
                @Suppress("UNCHECKED_CAST")
                val res = call("kidsTitles", mapOf("lineId" to lineId, "items" to items)) as? Map<String, Any?> ?: return
                val scores = (res["scores"] as? Map<String, Any?>).orEmpty().mapNotNull { (k, v) -> (v as? Number)?.let { k to it.toDouble() } }
                kidsScores = kidsScores + scores
            }
        } finally {
            fillingKids = false
        }
    }

    private suspend fun call(name: String, data: Map<String, Any?>): Any? = try {
        functions.getHttpsCallable(name).call(data).await().getData() ?: emptyMap<String, Any?>()
    } catch (e: FirebaseFunctionsException) {
        if (e.code in setOf(FirebaseFunctionsException.Code.RESOURCE_EXHAUSTED, FirebaseFunctionsException.Code.PERMISSION_DENIED,
                FirebaseFunctionsException.Code.UNAUTHENTICATED)) disabled = true
        null
    } catch (e: Exception) {
        null
    }

    companion object {
        /** Kids scores live in KIDS_SHARDS documents per line, {lineId}_{id % KIDS_SHARDS} (see the kidsTitles function). */
        const val KIDS_SHARDS = 8
    }
}
