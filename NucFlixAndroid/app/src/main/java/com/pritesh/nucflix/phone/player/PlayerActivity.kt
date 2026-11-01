package com.pritesh.nucflix.phone.player

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorsFactory
import androidx.media3.extractor.mkv.MatroskaExtractor
import androidx.media3.extractor.mkv.NucMatroskaExtractor
import androidx.media3.extractor.text.DefaultSubtitleParserFactory
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory
import androidx.media3.ui.PlayerView
import com.pritesh.nucflix.phone.NucFlixApp
import com.pritesh.nucflix.phone.data.Watching
import com.pritesh.nucflix.phone.ui.NucColors
import com.pritesh.nucflix.phone.ui.NucFlixTheme
import com.pritesh.nucflix.TsRebaseDataSource
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlin.math.abs

/** Full-screen player: ExoPlayer with the TV app's decoders and repairs, Media3's controls, PiP. */
@UnstableApi
class PlayerActivity : ComponentActivity() {
    private val app get() = application as NucFlixApp
    private lateinit var player: ExoPlayer
    private var request by mutableStateOf<PlayRequest?>(null)
    private var inPip by mutableStateOf(false)
    private var controlsVisible by mutableStateOf(true)
    private var error by mutableStateOf<String?>(null)
    /** Seconds left before the next episode starts (null = no countdown). */
    private var countdown by mutableStateOf<Int?>(null)
    private var countdownCancelled = false
    private var savedPosition = 0.0
    private var applyingPrefs = false
    private var playerView: PlayerView? = null
    private val scope = kotlinx.coroutines.MainScope()
    private val ai by lazy { PlayerAI(this, scope, app.cloud.uid, app.library.line?.id) { PlayerAI.grab(playerView) } }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val req = app.playRequest ?: run { finish(); return }
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        player = buildPlayer()
        play(req)
        setContent { NucFlixTheme { PlayerScreen() } }
    }

    /** A new title started while this one is open (e.g. from picture-in-picture): switch to it. */
    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        app.playRequest?.takeIf { it != request }?.let { saveNow(); play(it) }
    }

    // ---------------------------------------------------------------- player

    private fun buildPlayer(): ExoPlayer {
        // The phone's own decoders first; FFmpeg (DTS, TrueHD...) only for tracks they can't play.
        val renderers = DefaultRenderersFactory(this).setEnableDecoderFallback(true)
            .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
        // IPTV providers burst ahead then send in real time: start quickly, but want a real cushion after a stall.
        val load = DefaultLoadControl.Builder().setBufferDurationsMs(15_000, 50_000, 2_000, 5_000).build()
        return ExoPlayer.Builder(this, renderers).setLoadControl(load).build().apply {
            addListener(object : Player.Listener {
                override fun onPlaybackStateChanged(state: Int) {
                    if (state == Player.STATE_ENDED) onEnded()
                    if (state == Player.STATE_READY) error = null
                }

                override fun onPlayerError(e: PlaybackException) {
                    error = "This stream couldn't be played (${e.errorCodeName.removePrefix("ERROR_CODE_").lowercase().replace('_', ' ')})."
                }

                override fun onTracksChanged(tracks: Tracks) {
                    // Which languages ended up selected (as the TV app logs): handy when a stream "has no sound".
                    val selected = tracks.groups.filter { it.isSelected }.joinToString { g ->
                        val f = (0 until g.length).firstOrNull { g.isTrackSelected(it) }?.let { g.getTrackFormat(it) }
                        "${g.type}:${f?.sampleMimeType}/${f?.language}"
                    }
                    android.util.Log.i("NucFlixPlayer", "selected tracks: $selected")
                }

                override fun onTrackSelectionParametersChanged(parameters: TrackSelectionParameters) {
                    if (!applyingPrefs) rememberTrackChoice(parameters)
                }
            })
        }
    }

    private fun play(req: PlayRequest) {
        request = req
        error = null
        countdown = null
        countdownCancelled = false
        savedPosition = req.resumeAt
        ai.start(req)
        applyTrackPrefs()
        player.setMediaSource(mediaSource(req))
        if (req.resumeAt > 5) player.seekTo((req.resumeAt * 1000).toLong())
        player.prepare()
        player.playWhenReady = true
        // A downloaded file doesn't use the line: no "now playing", and downloads carry on.
        val fromLine = !req.url.startsWith("file:")
        app.library.streamingLineId = if (fromLine) app.library.line?.id else null
        if (fromLine) app.library.sync?.setNowPlaying(req.title, if (req.live) "live" else if (req.watching is Watching.EpisodeItem) "episode" else "movie")
        else app.library.sync?.setNowPlaying(null)
        if (req.live) app.library.sync?.saveProgress(req.watching, 0.0, 0.0, now = true)
    }

    private fun mediaSource(req: PlayRequest): MediaSource {
        val http = DefaultHttpDataSource.Factory().setUserAgent(com.pritesh.nucflix.phone.data.XtreamClient.USER_AGENT)
            .setAllowCrossProtocolRedirects(true).setConnectTimeoutMs(10_000).setReadTimeoutMs(15_000)
        val item = MediaItem.fromUri(Uri.parse(req.url))
        if (req.url.contains(".m3u8", ignoreCase = true)) {
            return HlsMediaSource.Factory(http).setAllowChunklessPreparation(true).setLoadErrorHandlingPolicy(RETRY).createMediaSource(item)
        }
        // Many IPTV TS feeds start mid-GOP or without IDR frames; accept any keyframe so they start.
        val extractors = DefaultExtractorsFactory()
            .setTsExtractorFlags(DefaultTsPayloadReaderFactory.FLAG_ALLOW_NON_IDR_KEYFRAMES or DefaultTsPayloadReaderFactory.FLAG_DETECT_ACCESS_UNITS)
            .setConstantBitrateSeekingEnabled(true)
        // Live TS goes through the timestamp re-baser (repairs feeds with audio hours off the video clock);
        // downloads (file:) are read from the phone.
        val source: DataSource.Factory = if (req.live) DataSource.Factory { TsRebaseDataSource(http.createDataSource()) } else DefaultDataSource.Factory(this, http)
        return ProgressiveMediaSource.Factory(source, withMkvRepair(extractors)).setLoadErrorHandlingPolicy(RETRY).createMediaSource(item)
    }

    /** Some providers' MKVs leave out the H.264 decoder setup; NucMatroskaExtractor rebuilds it from the stream. */
    private fun withMkvRepair(defaults: DefaultExtractorsFactory) = object : ExtractorsFactory {
        override fun createExtractors(): Array<Extractor> = swap(defaults.createExtractors())
        override fun createExtractors(uri: Uri, headers: Map<String, List<String>>): Array<Extractor> = swap(defaults.createExtractors(uri, headers))
        private fun swap(list: Array<Extractor>) = list.map { if (it is MatroskaExtractor) NucMatroskaExtractor(DefaultSubtitleParserFactory(), 0) else it }.toTypedArray()
    }

    // ---------------------------------------------------------------- audio & subtitle languages

    /** New titles start with the profile's languages (picked last here, on the TV or on the iPhone). */
    private fun applyTrackPrefs() {
        val p = app.cloud.selectedProfile ?: return
        applyingPrefs = true
        val b = player.trackSelectionParameters.buildUpon()
            .clearOverridesOfType(C.TRACK_TYPE_AUDIO).clearOverridesOfType(C.TRACK_TYPE_TEXT)
            .setPreferredAudioLanguage(p.audioLang.ifEmpty { null })
        if (p.subLang == "") b.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true).setPreferredTextLanguage(null)
        else b.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).setPreferredTextLanguage(p.subLang)
        player.trackSelectionParameters = b.build()
        applyingPrefs = false
    }

    /** A track picked in the player's menu becomes the profile's language for later titles, on every device. */
    private fun rememberTrackChoice(params: TrackSelectionParameters) {
        val profile = app.cloud.selectedProfile ?: return
        val prefs = HashMap<String, Any>()
        fun languageOf(type: Int): String? {
            val override = params.overrides.values.firstOrNull { it.type == type } ?: return null
            val group = player.currentTracks.groups.firstOrNull { it.mediaTrackGroup == override.mediaTrackGroup } ?: return null
            return override.trackIndices.firstOrNull()?.let { group.getTrackFormat(it).language }?.takeIf { it.isNotEmpty() && it != "und" }
        }
        languageOf(C.TRACK_TYPE_AUDIO)?.let { if (it != profile.audioLang) prefs["audioLang"] = it }
        if (C.TRACK_TYPE_TEXT in params.disabledTrackTypes) { if (profile.subLang != "") prefs["subLang"] = "" }
        else languageOf(C.TRACK_TYPE_TEXT)?.let { if (it != profile.subLang) prefs["subLang"] = it }
        if (prefs.isNotEmpty()) app.cloud.savePrefs(profile, prefs)
    }

    // ---------------------------------------------------------------- progress & next episode

    /** Called every second while the screen is up. */
    private fun tick() {
        val req = request ?: return
        val pos = player.currentPosition / 1000.0
        val dur = player.duration.takeIf { it > 0 && !req.live }?.div(1000.0) ?: 0.0
        ai.tick(pos, dur, player.isPlaying, req.live, req.title)
        if (req.live || dur <= 0) return
        // Ticks continue while paused: record only once the position moved (the sync throttles writes further).
        // Past the credits a title counts as watched.
        if (abs(pos - savedPosition) >= 4) {
            savedPosition = pos
            app.library.sync?.saveProgress(req.watching, if (ai.pastCredits(pos)) dur else pos, dur)
        }
        val autoplay = app.cloud.selectedProfile?.autoplayNext != false
        val creditsAt = ai.creditsReachedAt
        countdown = when {
            req.nextEpisode == null || !autoplay || countdownCancelled -> null
            // The credits started: count down from 10 to the next episode.
            creditsAt != null -> (10 - ((System.currentTimeMillis() - creditsAt) / 1000).toInt()).also { if (it <= 0) { playNext(); return } }
            dur > 120 && dur - pos <= 25 && player.isPlaying -> (dur - pos).toInt().coerceAtLeast(0)
            else -> null
        }
    }

    private fun onEnded() {
        val req = request ?: return
        if (!req.live) app.library.sync?.saveProgress(req.watching, player.duration / 1000.0, player.duration / 1000.0, now = true)
        if (req.nextEpisode != null && app.cloud.selectedProfile?.autoplayNext != false && !countdownCancelled) playNext() else finish()
    }

    private fun playNext() {
        val req = request ?: return
        val s = req.series ?: return
        saveNow()
        Playback.episodeRequest(this, s, req.episodes, req.episodeIndex + 1, 0.0)?.let(::play)
    }

    private fun saveNow() {
        val req = request ?: return
        if (req.live) return
        val dur = player.duration.takeIf { it > 0 }?.div(1000.0) ?: return
        val pos = player.currentPosition / 1000.0
        app.library.sync?.saveProgress(req.watching, if (ai.pastCredits(pos)) dur else pos, dur, now = true)
    }

    // ---------------------------------------------------------------- lifecycle & PiP

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (player.isPlaying && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) enterPip()
    }

    private fun enterPip() {
        runCatching { enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build()) }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        inPip = isInPictureInPictureMode
    }

    override fun onPause() {
        super.onPause()
        saveNow()
        if (!isInPictureInPictureMode) player.pause()
    }

    override fun onStop() {
        super.onStop()
        saveNow()
        app.library.sync?.flush()
        // Leaving PiP by closing it stops the activity: playback ends then.
        if (isInPictureInPictureMode || isFinishing) player.pause()
    }

    override fun onDestroy() {
        super.onDestroy()
        if (::player.isInitialized) {
            saveNow()
            app.library.sync?.flush()
            player.release()
        }
        ai.stop()
        scope.cancel()
        app.library.sync?.setNowPlaying(null)
        app.library.streamingLineId = null
    }

    // ---------------------------------------------------------------- UI

    @androidx.compose.runtime.Composable
    private fun PlayerScreen() {
        LaunchedEffect(Unit) { while (true) { delay(1000); tick() } }
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            AndroidView(
                factory = { ctx ->
                    PlayerView(ctx).apply {
                        layoutParams = FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                        player = this@PlayerActivity.player
                        setShowNextButton(false)
                        setShowPreviousButton(false)
                        setShowSubtitleButton(true) // hidden by default
                        playerView = this
                        setControllerVisibilityListener(PlayerView.ControllerVisibilityListener { v -> controlsVisible = v == android.view.View.VISIBLE })
                    }
                },
                update = { it.useController = !inPip },
                modifier = Modifier.fillMaxSize()
            )
            val req = request
            if (!inPip && req != null && controlsVisible) {
                Row(Modifier.safeDrawingPadding().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { finish() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Color.White) }
                    Column {
                        Text(req.title, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                        req.subtitle?.let { Text(it, fontSize = 13.sp, color = Color.White.copy(alpha = 0.75f)) }
                    }
                }
            }
            error?.let { msg ->
                Column(Modifier.align(Alignment.Center).background(Color.Black.copy(alpha = 0.8f), RoundedCornerShape(10.dp)).padding(20.dp),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(msg)
                    Row {
                        TextButton(onClick = { request?.let { r -> play(r.copy(resumeAt = player.currentPosition / 1000.0)) } }) { Text("Try Again") }
                        TextButton(onClick = { finish() }) { Text("Close", color = Color.White) }
                    }
                }
            }
            ai.skipIntroTo?.let { to ->
                if (!inPip) Button(onClick = { player.seekTo((to * 1000).toLong()) },
                    modifier = Modifier.align(Alignment.BottomEnd).safeDrawingPadding().padding(end = 24.dp, bottom = 96.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black)) { Text("Skip Intro", fontWeight = FontWeight.SemiBold) }
            }
            ai.offAir?.let { label -> if (!inPip) OffAirBanner(label) }
            val left = countdown
            if (!inPip && left != null) {
                Column(Modifier.align(Alignment.BottomEnd).safeDrawingPadding().padding(24.dp)
                    .background(Color.Black.copy(alpha = 0.75f), RoundedCornerShape(10.dp)).padding(16.dp)) {
                    Text("Next episode in $left s", fontWeight = FontWeight.SemiBold)
                    req?.nextEpisode?.let { Text("S${it.season} E${it.episodeNum} • ${it.cleanTitle}", fontSize = 13.sp, color = NucColors.Muted) }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = { playNext() }, colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black)) { Text("Play Now") }
                        TextButton(onClick = { countdownCancelled = true; countdown = null }) { Text("Cancel", color = Color.White) }
                    }
                }
            }
        }
    }

    /** The live channel looks off air: offer the same station from another source, or keep watching. */
    @androidx.compose.runtime.Composable
    private fun androidx.compose.foundation.layout.BoxScope.OffAirBanner(label: String) {
        val req = request ?: return
        val channel = (req.watching as? Watching.LiveItem)?.let { app.library.catalog.liveById[it.streamId] }
        val alt = channel?.let { com.pritesh.nucflix.phone.data.SmartAI.alternatives(it, app.library.catalog.live).firstOrNull() }
        val msg = mapOf("black" to "This channel is showing a black screen.", "frozen" to "This channel's picture looks frozen.",
            "offline" to "This channel looks off air.")[label] ?: "This channel may not be working."
        Column(Modifier.align(Alignment.TopCenter).safeDrawingPadding().padding(top = 56.dp)
            .background(Color.Black.copy(alpha = 0.85f), RoundedCornerShape(10.dp)).padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(msg, fontWeight = FontWeight.SemiBold)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (alt != null) Button(onClick = { ai.offAir = null; Playback.liveRequest(this@PlayerActivity, alt)?.let { saveNow(); play(it) } },
                    colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black)) { Text("Try ${alt.cleanName}") }
                TextButton(onClick = { ai.offAir = null }) { Text("Keep Watching", color = Color.White) }
            }
        }
    }

    companion object {
        /**
         * Single-connection IPTV lines briefly reject a new connection while the previous one is torn down
         * (403 / 458 / 509 / 884 / 5xx): retry those a few times instead of failing the stream.
         */
        private val RETRY: LoadErrorHandlingPolicy = object : DefaultLoadErrorHandlingPolicy(6) {
            override fun getRetryDelayMsFor(info: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
                val code = (info.exception as? HttpDataSource.InvalidResponseCodeException)?.responseCode
                if (code != null) {
                    val busy = code == 403 || code == 429 || code == 458 || code == 509 || code == 884 || code >= 500
                    return if (busy && info.errorCount <= 4) 800L * info.errorCount else C.TIME_UNSET
                }
                return super.getRetryDelayMsFor(info)
            }
        }
    }
}
