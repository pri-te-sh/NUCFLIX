package com.pritesh.nucflix.phone.player

import android.content.Context
import android.content.Intent
import com.pritesh.nucflix.phone.NucFlixApp
import com.pritesh.nucflix.phone.data.Episode
import com.pritesh.nucflix.phone.data.LiveChannel
import com.pritesh.nucflix.phone.data.Movie
import com.pritesh.nucflix.phone.data.Series
import com.pritesh.nucflix.phone.data.Watching

/** What the player plays; for an episode, the show's episodes so it can go on to the next. */
data class PlayRequest(
    val url: String,
    val title: String,
    val subtitle: String?,
    val watching: Watching,
    val resumeAt: Double,
    val live: Boolean,
    val episodes: List<Episode> = emptyList(),
    val episodeIndex: Int = -1,
    val series: Series? = null
) {
    val nextEpisode: Episode? get() = episodes.getOrNull(episodeIndex + 1)
}

/** Builds play requests from catalog items and opens the player. */
object Playback {
    private fun app(context: Context) = context.applicationContext as NucFlixApp

    fun open(context: Context, request: PlayRequest) {
        app(context).playRequest = request
        context.startActivity(Intent(context, PlayerActivity::class.java))
    }

    fun movie(context: Context, m: Movie, resumeAt: Double) {
        val client = app(context).library.client ?: return
        open(context, PlayRequest(client.movieUrl(m), m.cleanName, null,
            Watching.MovieItem(m.streamId, m.cleanName, m.icon, m.ext), resumeAt, live = false))
    }

    fun episode(context: Context, s: Series, episodes: List<Episode>, index: Int, resumeAt: Double) {
        val request = episodeRequest(context, s, episodes, index, resumeAt) ?: return
        open(context, request)
    }

    fun episodeRequest(context: Context, s: Series, episodes: List<Episode>, index: Int, resumeAt: Double): PlayRequest? {
        val client = app(context).library.client ?: return null
        val ep = episodes.getOrNull(index) ?: return null
        return PlayRequest(client.episodeUrl(ep.episodeId, ep.ext), s.cleanName, "S${ep.season} E${ep.episodeNum} • ${ep.cleanTitle}",
            Watching.EpisodeItem(s.seriesId, ep.episodeId, ep.season, ep.episodeNum, ep.cleanTitle, s.cleanName, s.cover, ep.ext),
            resumeAt, live = false, episodes = episodes, episodeIndex = index, series = s)
    }

    fun live(context: Context, c: LiveChannel) {
        val client = app(context).library.client ?: return
        open(context, PlayRequest(client.liveUrl(c.streamId), c.cleanName, null, Watching.LiveItem(c.streamId, c.cleanName, c.icon), 0.0, live = true))
    }
}
