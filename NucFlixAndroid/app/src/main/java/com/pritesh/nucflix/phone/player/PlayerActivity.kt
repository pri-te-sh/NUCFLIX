package com.pritesh.nucflix.phone.player

import android.app.PictureInPictureParams
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.ScaleGestureDetector
import android.util.Rational
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.Brightness6
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.ScreenRotation
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
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
import androidx.media3.common.ForwardingPlayer
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
import androidx.media3.session.MediaSession
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.pritesh.nucflix.phone.NucFlixApp
import com.pritesh.nucflix.phone.data.Kind
import com.pritesh.nucflix.phone.data.Watching
import com.pritesh.nucflix.phone.ui.GuideSheet
import com.pritesh.nucflix.phone.ui.NucColors
import com.pritesh.nucflix.phone.ui.NucFlixTheme
import com.pritesh.nucflix.TsRebaseDataSource
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs

/**
 * Full-screen player: ExoPlayer with the TV app's decoders and repairs, Media3's controls, PiP, a media session
 * (headset / Bluetooth buttons), screen lock, brightness, pinch to fill, and the next-episode flow.
 */
@UnstableApi
class PlayerActivity : ComponentActivity() {
    private val app get() = application as NucFlixApp
    private lateinit var player: ExoPlayer
    private var request by mutableStateOf<PlayRequest?>(null)
    private var inPip by mutableStateOf(false)
    private var controlsVisible by mutableStateOf(true)
    private var error by mutableStateOf<String?>(null)
    /** The Next Episode button is up (credits or the last seconds), with how far its autoplay fill has run (0..1). */
    private var nextFill by mutableStateOf<Float?>(null)
    /** "Watch Credits" was picked: the next episode waits for the end (then a short countdown). */
    private var watchCredits by mutableStateOf(false)
    private var endCountdown by mutableStateOf<Int?>(null)
    /** Paused after a few episodes in a row with nobody touching the phone. */
    private var stillWatching by mutableStateOf(false)
    private var autoplays = 0
    private var liveRetries = 0
    private var locked by mutableStateOf(false)
    private var zoomed by mutableStateOf(false)
    private var portrait by mutableStateOf(false)
    private var brightness by mutableFloatStateOf(0.5f)
    private var showGuide by mutableStateOf(false)
    private var session: MediaSession? = null
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
        brightness = window.attributes.screenBrightness.takeIf { it >= 0 }
            ?: (Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS, 128) / 255f)
        // Headset / Bluetooth buttons and the picture-in-picture window's play / pause go through the session.
        session = runCatching { MediaSession.Builder(this, controls).build() }.getOrNull()
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
                    if (state == Player.STATE_READY) { error = null; liveRetries = 0 }
                }

                override fun onPlayerError(e: PlaybackException) {
                    // A live stream that stalls or drops: reconnect a few times before giving up.
                    val req = request
                    if (req?.live == true && liveRetries < 3) {
                        liveRetries++
                        scope.launch {
                            delay(1_500)
                            if (request === req) { player.setMediaSource(mediaSource(req)); player.prepare(); player.playWhenReady = true }
                        }
                        return
                    }
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

    /** The player as the controls and the media session see it: "next" plays the next episode. */
    private val controls: Player by lazy {
        object : ForwardingPlayer(player) {
            private fun hasNext() = request?.nextEpisode != null
            override fun getAvailableCommands(): Player.Commands = super.getAvailableCommands().buildUpon()
                .apply { if (hasNext()) add(Player.COMMAND_SEEK_TO_NEXT).add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM) }.build()
            override fun isCommandAvailable(command: Int) =
                (hasNext() && (command == Player.COMMAND_SEEK_TO_NEXT || command == Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)) || super.isCommandAvailable(command)
            override fun hasNextMediaItem() = hasNext() || super.hasNextMediaItem()
            override fun seekToNext() { if (hasNext()) playNext(manual = true) else super.seekToNext() }
            override fun seekToNextMediaItem() { if (hasNext()) playNext(manual = true) else super.seekToNextMediaItem() }
        }
    }

    private fun play(req: PlayRequest) {
        request = req
        error = null
        nextFill = null
        watchCredits = false
        endCountdown = null
        stillWatching = false
        liveRetries = 0
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
        endCountdown?.let { left -> if (left <= 1) { endCountdown = null; autoNext() } else endCountdown = left - 1; return }
        // The Next Episode button: from the start of the credits (or the last 25 s), filling up until autoplay.
        val autoplay = app.cloud.selectedProfile?.autoplayNext != false
        val creditsAt = ai.creditsReachedAt
        val now = System.currentTimeMillis()
        val window = req.nextEpisode != null && !watchCredits && !stillWatching && (creditsAt != null || (dur > 120 && dur - pos <= 25))
        nextFill = when {
            !window -> null
            !autoplay -> 0f
            creditsAt != null -> ((now - creditsAt) / 10_000f).coerceIn(0f, 1f)
            else -> (1 - (dur - pos) / 25).toFloat().coerceIn(0f, 1f)
        }
        if (window && autoplay && creditsAt != null && now - creditsAt >= 10_000 && player.isPlaying) autoNext()
    }

    private fun onEnded() {
        val req = request ?: return
        if (!req.live) app.library.sync?.saveProgress(req.watching, player.duration / 1000.0, player.duration / 1000.0, now = true)
        when {
            req.nextEpisode == null || app.cloud.selectedProfile?.autoplayNext == false -> finish()
            watchCredits -> endCountdown = 5
            else -> autoNext()
        }
    }

    /** On to the next episode by itself, but after three in a row ask whether anyone's still watching. */
    private fun autoNext() {
        if (stillWatching) return
        if (autoplays >= MAX_AUTOPLAYS) { stillWatching = true; nextFill = null; player.pause(); return }
        autoplays++
        playNext(manual = false)
    }

    private fun playNext(manual: Boolean) {
        val req = request ?: return
        val s = req.series ?: return
        if (manual) autoplays = 0
        saveNow()
        Playback.episodeRequest(this, s, req.episodes, req.episodeIndex + 1, 0.0)?.let(::play)
    }

    private fun changeBrightness(value: Float) {
        brightness = value.coerceIn(0.02f, 1f)
        // The window's own brightness: the phone's setting comes back when the player closes.
        window.attributes = window.attributes.apply { screenBrightness = brightness }
    }

    private fun rotate() {
        portrait = !portrait
        requestedOrientation = if (portrait) android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
            else android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
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
        session?.release()
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
                        player = controls
                        setShowNextButton(true) // shown for episodes with one after them
                        setShowPreviousButton(false)
                        setShowSubtitleButton(true) // hidden by default
                        playerView = this
                        setControllerVisibilityListener(PlayerView.ControllerVisibilityListener { v -> controlsVisible = v == android.view.View.VISIBLE })
                        // Pinch out to fill the screen (cropping the edges), pinch in to fit the whole picture again.
                        val pinch = ScaleGestureDetector(ctx, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
                            var total = 1f
                            override fun onScaleBegin(d: ScaleGestureDetector): Boolean { total = 1f; return true }
                            override fun onScale(d: ScaleGestureDetector): Boolean { total *= d.scaleFactor; return true }
                            override fun onScaleEnd(d: ScaleGestureDetector) { if (total > 1.15f) zoomed = true else if (total < 0.87f) zoomed = false }
                        })
                        setOnTouchListener { _, ev -> pinch.onTouchEvent(ev); ev.pointerCount > 1 || pinch.isInProgress }
                    }
                },
                update = {
                    it.useController = !inPip && !locked
                    it.setShowNextButton(request?.nextEpisode != null)
                    if (locked) it.hideController()
                    it.resizeMode = if (zoomed) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
                },
                modifier = Modifier.fillMaxSize()
            )
            val req = request
            if (!inPip && !locked && req != null && controlsVisible) {
                TopBar(req)
                BrightnessBar()
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
                if (!inPip && !locked) Button(onClick = { player.seekTo((to * 1000).toLong()) },
                    modifier = Modifier.align(Alignment.BottomEnd).safeDrawingPadding().padding(end = 24.dp, bottom = 96.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black)) { Text("Skip Intro", fontWeight = FontWeight.SemiBold) }
            }
            ai.offAir?.let { label -> if (!inPip && !locked) OffAirBanner(label) }
            if (!inPip && !locked) NextEpisodeControls()
            if (locked && !inPip) LockOverlay()
            if (showGuide) (req?.watching as? Watching.LiveItem)?.let { live ->
                GuideSheet(app.library.epg, req.title, live.streamId) { showGuide = false }
            }
        }
    }

    /** Title, and the player's own buttons: guide + favourite (live), fill, rotate, picture-in-picture, lock. */
    @androidx.compose.runtime.Composable
    private fun TopBar(req: PlayRequest) {
        val live = req.watching as? Watching.LiveItem
        val sync = app.library.sync
        @Suppress("UNUSED_VARIABLE") val rev = app.library.revision // the favourite star follows My List
        val title = @androidx.compose.runtime.Composable { m: Modifier ->
            Column(m) {
                Text(req.title, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
                val sub = req.subtitle ?: live?.let { app.library.epg.now(it.streamId)?.title }
                sub?.let { Text(it, fontSize = 13.sp, color = Color.White.copy(alpha = 0.75f), maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis) }
            }
        }
        val buttons = @androidx.compose.runtime.Composable {
            if (live != null) {
                LaunchedEffect(live.streamId) { app.library.epg.load(live.streamId) }
                IconButton(onClick = { showGuide = true }) { Icon(Icons.Filled.CalendarMonth, "TV guide", tint = Color.White) }
                val fav = sync?.isFavorite(Kind.LIVE, live.streamId) == true
                val channel = app.library.catalog.liveById[live.streamId]
                IconButton(onClick = { sync?.setFavorite(Kind.LIVE, live.streamId, live.title, live.artwork, null, channel?.categoryId, !fav) }) {
                    Icon(if (fav) Icons.Filled.Star else Icons.Filled.StarBorder, if (fav) "Remove favourite" else "Add favourite",
                        tint = if (fav) Color(0xFFF5C518) else Color.White)
                }
            }
            IconButton(onClick = { zoomed = !zoomed }) { Icon(Icons.Filled.AspectRatio, if (zoomed) "Fit to screen" else "Fill screen", tint = if (zoomed) NucColors.Red else Color.White) }
            IconButton(onClick = { rotate() }) { Icon(Icons.Filled.ScreenRotation, "Rotate", tint = Color.White) }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) IconButton(onClick = { enterPip() }) { Icon(Icons.Filled.PictureInPictureAlt, "Picture in picture", tint = Color.White) }
            IconButton(onClick = { locked = true; playerView?.hideController() }) { Icon(Icons.Filled.Lock, "Lock screen", tint = Color.White) }
        }
        val back = @androidx.compose.runtime.Composable { IconButton(onClick = { finish() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Color.White) } }
        // Portrait is too narrow for the title and six buttons on one line: the buttons go underneath.
        if (androidx.compose.ui.platform.LocalConfiguration.current.orientation == Configuration.ORIENTATION_PORTRAIT) {
            Column(Modifier.fillMaxWidth().safeDrawingPadding().padding(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) { back(); title(Modifier.weight(1f)) }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) { buttons() }
            }
        } else Row(Modifier.fillMaxWidth().safeDrawingPadding().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            back(); title(Modifier.weight(1f)); buttons()
        }
    }

    /** Drag up and down to change the screen brightness (for this player only). */
    @androidx.compose.runtime.Composable
    private fun BoxScope.BrightnessBar() {
        Column(Modifier.align(Alignment.CenterStart).safeDrawingPadding().padding(start = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Filled.Brightness6, "Brightness", tint = Color.White, modifier = Modifier.size(20.dp))
            Box(Modifier.padding(top = 8.dp).width(40.dp).height(150.dp)
                .pointerInput(Unit) {
                    detectVerticalDragGestures { change, drag ->
                        change.consume()
                        changeBrightness(brightness - drag / size.height)
                        playerView?.showController() // keep the controls up while dragging
                    }
                }
                .pointerInput(Unit) { detectTapGestures { o -> changeBrightness(1 - o.y / size.height) } },
                contentAlignment = Alignment.BottomCenter) {
                Box(Modifier.width(5.dp).fillMaxHeight().clip(RoundedCornerShape(3.dp)).background(Color.White.copy(alpha = 0.25f)))
                Box(Modifier.width(5.dp).fillMaxHeight(brightness).clip(RoundedCornerShape(3.dp)).background(Color.White))
            }
        }
    }

    /** Locked: touches do nothing; a tap shows the unlock button for a few seconds. */
    @androidx.compose.runtime.Composable
    private fun BoxScope.LockOverlay() {
        var hint by remember { mutableStateOf(true) }
        var taps by remember { mutableStateOf(0) }
        LaunchedEffect(taps) { hint = true; delay(3_000); hint = false }
        Box(Modifier.fillMaxSize().clickable(remember { MutableInteractionSource() }, indication = null) { taps++ })
        if (hint) Button(onClick = { locked = false; hint = false; playerView?.showController() },
            modifier = Modifier.align(Alignment.BottomCenter).safeDrawingPadding().padding(bottom = 32.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.9f), contentColor = Color.Black)) {
            Icon(Icons.Filled.LockOpen, null); Text(" Tap to Unlock", fontWeight = FontWeight.SemiBold)
        }
    }

    /** "Watch Credits" / "Next Episode" (filling up until autoplay), the short end countdown, and "Still watching?". */
    @androidx.compose.runtime.Composable
    private fun BoxScope.NextEpisodeControls() {
        val req = request ?: return
        val next = req.nextEpisode
        val fill = nextFill
        if (fill != null && next != null) {
            Row(Modifier.align(Alignment.BottomEnd).safeDrawingPadding().padding(end = 24.dp, bottom = 100.dp), // clear of the seek bar, and doesn't move when the controls hide
                horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Watch Credits", Modifier.clip(RoundedCornerShape(4.dp)).background(Color.Black.copy(alpha = 0.45f))
                    .clickable { watchCredits = true; nextFill = null }.padding(horizontal = 18.dp, vertical = 12.dp), fontWeight = FontWeight.Bold)
                Box(Modifier.clip(RoundedCornerShape(4.dp)).background(Color.White).clickable { playNext(manual = true) }) {
                    Box(Modifier.matchParentSize(), contentAlignment = Alignment.CenterStart) {
                        Box(Modifier.fillMaxHeight().fillMaxWidth(fill).background(Color(0xFFB8B8B8)))
                    }
                    Row(Modifier.padding(horizontal = 20.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.PlayArrow, null, tint = Color.Black)
                        Text(" Next Episode", color = Color.Black, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
        endCountdown?.let { left ->
            Column(Modifier.align(Alignment.BottomEnd).safeDrawingPadding().padding(end = 24.dp, bottom = 100.dp)
                .background(Color.Black.copy(alpha = 0.75f), RoundedCornerShape(10.dp)).padding(16.dp)) {
                Text("Next episode in $left s", fontWeight = FontWeight.SemiBold)
                next?.let { Text("S${it.season} E${it.episodeNum} • ${it.cleanTitle}", fontSize = 13.sp, color = NucColors.Muted) }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { endCountdown = null; playNext(manual = true) },
                        colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black)) { Text("Play Now") }
                    TextButton(onClick = { endCountdown = null; finish() }) { Text("Close", color = Color.White) }
                }
            }
        }
        if (stillWatching) {
            Column(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.8f)).clickable(remember { MutableInteractionSource() }, indication = null) {},
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Text("Are you still watching?", fontSize = 24.sp, fontWeight = FontWeight.Bold)
                Text(next?.let { "Up next: S${it.season} E${it.episodeNum} • ${it.cleanTitle}" }.orEmpty(), fontSize = 14.sp, color = Color.White.copy(alpha = 0.75f), modifier = Modifier.padding(top = 6.dp, bottom = 18.dp))
                Button(onClick = { stillWatching = false; playNext(manual = true) }, modifier = Modifier.widthIn(min = 260.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color.Black)) { Text("Continue Watching", fontWeight = FontWeight.Bold) }
                Spacer(Modifier.height(10.dp))
                Button(onClick = { finish() }, modifier = Modifier.widthIn(min = 260.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.18f), contentColor = Color.White)) { Text("Back to Browse", fontWeight = FontWeight.Bold) }
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
        /** Episodes that start by themselves before "Are you still watching?". */
        private const val MAX_AUTOPLAYS = 3

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
