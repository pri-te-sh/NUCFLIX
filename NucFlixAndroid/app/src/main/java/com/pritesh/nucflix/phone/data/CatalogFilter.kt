package com.pritesh.nucflix.phone.data

/**
 * The adult and kids filters, the same rules as the Fire TV and iPhone apps.
 *
 * Adult content (unless the profile shows it): categories named adult/XXX/18+ or AI-tagged adult, and titles the
 * provider flags. Kids profiles, three layers: (1) category rules (no mature-looking names; a kid-looking name or
 * an AI kids score >= 0.6; untagged categories stay hidden), (2) title rules (no adult flag, mature words or
 * genres), (3) the AI title score >= 0.6 (unchecked titles stay hidden and wait in kidsPending).
 */
object CatalogFilter {
    private val adultRe = Regex("\\b(adult|xxx|porn|erotic|for adults)\\b|18\\s?\\+", RegexOption.IGNORE_CASE)
    private val kidsBlockCat = Regex(
        "\\b(adults?|xxx|porn|erotic|nsfw|uncensored|nude|sexy|horror|terror|slasher|gore|thriller|crime|war|mature|after dark|late night|ppv|ufc|wwe|mma|boxing)\\b|18\\s?\\+",
        RegexOption.IGNORE_CASE
    )
    private val kidsAllowCat = Regex(
        "\\b(kids?|children'?s?|cartoons?|junior|jr|toddlers?|pre-?school|bab(y|ies)|nursery|family|nickelodeon|nick|cbeebies|boomerang|pogo)\\b",
        RegexOption.IGNORE_CASE
    )
    private val kidsBadGenres = setOf("adult", "horror", "thriller", "crime")
    private val kidsBlockTitle = Regex("\\b(xxx|porn|erotic|nsfw|uncensored|nude|sexy|horror|slasher|gore|adult|for adults)\\b|18\\s?\\+", RegexOption.IGNORE_CASE)
    private val kidsBlockGenre = Regex("\\b(horror|thriller|crime|war|erotic|adult)\\b", RegexOption.IGNORE_CASE)
    const val KIDS_MIN = 0.6

    private fun kidsCategoryOk(name: String, tag: CategoryTag?): Boolean {
        if (kidsBlockCat.containsMatchIn(name)) return false
        if (tag != null && (tag.adult > 0.3 || tag.genre in kidsBadGenres)) return false
        return kidsAllowCat.containsMatchIn(name) || (tag != null && tag.kids >= KIDS_MIN)
    }

    private fun kidsTitleRulesOk(name: String, isAdult: Boolean, genre: String?) =
        !isAdult && !kidsBlockTitle.containsMatchIn(name) && !(genre != null && kidsBlockGenre.containsMatchIn(genre))

    fun apply(raw: RawCatalog, profile: CloudProfile, smart: SmartData?): FilteredCatalog {
        val kids = profile.kids
        val showAdult = profile.showAdult && !kids
        val pending = ArrayList<Triple<Kind, Int, String>>()

        fun hiddenCategory(kind: Kind, c: Category): Boolean {
            val tag = smart?.tag(kind, c.id)
            if (!showAdult && (adultRe.containsMatchIn(c.name) || (tag != null && (tag.adult > 0.7 || tag.genre == "adult")))) return true
            return kids && !kidsCategoryOk(c.name, tag)
        }
        fun visible(kind: Kind, cats: List<Category>) = cats.filterNot { hiddenCategory(kind, it) }
        val liveCats = visible(Kind.LIVE, raw.liveCategories)
        val movieCats = visible(Kind.MOVIE, raw.movieCategories)
        val seriesCats = visible(Kind.SERIES, raw.seriesCategories)
        if (showAdult) {
            return FilteredCatalog(liveCats, movieCats, seriesCats, raw.live, raw.movies, raw.series, emptyList(), filtering = false)
        }
        val liveOk = liveCats.mapTo(HashSet()) { it.id }
        val movieOk = movieCats.mapTo(HashSet()) { it.id }
        val seriesOk = seriesCats.mapTo(HashSet()) { it.id }

        fun kidsOk(kind: Kind, id: Int, name: String, isAdult: Boolean, genre: String?): Boolean {
            if (!kidsTitleRulesOk(name, isAdult, genre)) return false
            val score = smart?.kidsScore(kind, id)
            if (score == null) { pending += Triple(kind, id, name); return false }
            return score >= KIDS_MIN
        }
        // Series first, then movies, then channels: the order kids titles are sent for checking.
        val series = raw.series.filter { it.categoryId in seriesOk && (!kids || kidsOk(Kind.SERIES, it.seriesId, it.name, false, it.genre)) }
        val movies = raw.movies.filter { !it.isAdult && it.categoryId in movieOk && (!kids || kidsOk(Kind.MOVIE, it.streamId, it.name, it.isAdult, null)) }
        val live = raw.live.filter { !it.isDivider && !it.isAdult && it.categoryId in liveOk && (!kids || kidsOk(Kind.LIVE, it.streamId, it.name, it.isAdult, null)) }
        return FilteredCatalog(liveCats, movieCats, seriesCats, live, movies, series, pending, filtering = true)
    }
}
