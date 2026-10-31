package com.pritesh.nucflix.phone.data

/** "live" | "movie" | "series": also the kind keys used in Firestore (favorites, tags, kids scores). */
enum class Kind(val key: String) { LIVE("live"), MOVIE("movie"), SERIES("series") }

data class Category(val id: String, val name: String, val cleanName: String, val prefix: String?) {
    /** "IN · Hindi": the prefix tells apart the many same-named categories. */
    val label: String get() = if (prefix != null) "$prefix · $cleanName" else cleanName
}

data class LiveChannel(
    val streamId: Int, val num: Int, val name: String, val cleanName: String, val badges: List<String>,
    val icon: String, val categoryId: String, val isAdult: Boolean, val isDivider: Boolean
)

data class Movie(
    val streamId: Int, val name: String, val cleanName: String, val badges: List<String>, val icon: String,
    val rating: String, val added: Long, val categoryId: String, val ext: String, val isAdult: Boolean
)

data class Series(
    val seriesId: Int, val name: String, val cleanName: String, val cover: String, val backdrop: String,
    val plot: String, val genre: String, val rating: String, val releaseDate: String, val lastModified: Long,
    val categoryId: String
)

data class Episode(
    val episodeId: String, val season: Int, val episodeNum: Int, val title: String, val cleanTitle: String,
    val ext: String, val image: String, val plot: String, val durationSecs: Int
)

data class SeriesInfo(val plot: String, val cast: String, val genre: String, val releaseDate: String, val cover: String,
                      val backdrop: String, val episodesBySeason: Map<Int, List<Episode>>) {
    val seasons: List<Int> get() = episodesBySeason.keys.sorted()
    val allEpisodes: List<Episode> get() = seasons.flatMap { episodesBySeason[it].orEmpty() }
}

data class MovieInfo(val plot: String, val cast: String, val director: String, val genre: String, val releaseDate: String,
                     val durationSecs: Int, val backdrop: String)

/** Everything the provider lists for a line (before the adult / kids filters). */
data class RawCatalog(
    val liveCategories: List<Category>, val live: List<LiveChannel>,
    val movieCategories: List<Category>, val movies: List<Movie>,
    val seriesCategories: List<Category>, val series: List<Series>
)
