package com.pritesh.nucflix.phone.data

/** A cleaned-up provider title: "UK | Sky Sports 1 ᴴᴰ" -> "Sky Sports 1" with prefix "UK" and badge "HD". */
data class FormattedTitle(val cleanTitle: String, val prefixTag: String?, val badges: List<String>, val isSectionDivider: Boolean)

/** The same rules as the iPhone and Fire TV apps (XtreamTextFormatter). */
object XtreamFormatter {
    private val prefixSeparators = listOf(" | ", "| ", " - ", ": ")
    private val trailingJunk = setOf('|', '-', '/', '•', '◉', ' ')
    private val cache = HashMap<String, FormattedTitle>()
    private val unicodeTags = listOf("⁴ᴷ", "³⁸⁴⁰ᴾ", "ᴰᵒˡᵇʸ",
        "ⱽᶦˢᶦᵒⁿ", "ᴿᴬᵂ", "ᴴᴰ", "◉")
    private val spaces = Regex("\\s{2,}")
    private val trailingParens = Regex("(\\s*\\([A-Za-z0-9\\-\\s]{2,14}\\))+$")
    private val dividerChars = Regex("[#*=]")

    private fun stripTags(s: String): String {
        var out = s
        unicodeTags.forEach { out = out.replace(it, "") }
        return out.replace(spaces, " ").trim()
    }

    @Synchronized
    fun format(raw: String?): FormattedTitle {
        val input = raw?.trim().orEmpty()
        if (input.isEmpty()) return FormattedTitle("Untitled", null, emptyList(), false)
        cache[input]?.let { return it }
        if (cache.size > 60_000) cache.clear()

        val hashes = input.count { it == '#' || it == '*' || it == '=' }
        if (hashes >= 4 || input.startsWith("###") || input.endsWith("###")) {
            val stripped = stripTags(input.replace(dividerChars, "")).trim()
            return FormattedTitle(stripped.ifEmpty { "Featured Section" }, null, emptyList(), true).also { cache[input] = it }
        }

        val badges = mutableListOf<String>()
        val upper = input.uppercase()
        if ("⁴ᴷ" in input || "4K" in upper || "UHD" in upper || "³⁸⁴⁰" in input) badges += "4K"
        if ("ᴰᵒˡᵇʸ" in input || "DOLBY" in upper) badges += "DOLBY"
        if ("ᴿᴬᵂ" in input || " RAW" in upper) badges += "RAW"
        if ("ᴴᴰ" in input || upper.endsWith(" HD") || " HD " in upper || "FHD" in upper) { if ("4K" !in badges) badges += "HD" }
        if ("HEVC" in upper) badges += "HEVC"

        var text = stripTags(input)
        var prefix: String? = null
        for (sep in prefixSeparators) {
            val idx = text.indexOf(sep)
            if (idx > 0) {
                val candidate = text.substring(0, idx).trim()
                if (candidate.length in 2..12) {
                    prefix = candidate.replace("|", "").trim()
                    text = text.substring(idx + sep.length).trim()
                    break
                }
            }
        }
        if (text.endsWith(")")) text = text.replace(trailingParens, "").trim()
        while (text.isNotEmpty() && text.last() in trailingJunk) text = text.dropLast(1)
        return FormattedTitle(text.ifEmpty { input }, prefix, badges, false).also { cache[input] = it }
    }
}

/** Lowercase letters and digits only, for search ("Spider-Man: No Way Home" -> "spider man no way home"). */
fun searchNormalize(text: String): String =
    text.lowercase().replace("'", "").replace("’", "").replace(Regex("[^a-z0-9À-ɏ]+"), " ").trim()
