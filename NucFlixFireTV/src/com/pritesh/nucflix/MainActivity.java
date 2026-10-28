package com.pritesh.nucflix;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.SystemClock;
import android.text.InputType;
import android.util.Base64;
import android.view.PixelCopy;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityNodeProvider;
import android.view.inputmethod.EditorInfo;
import android.webkit.JavascriptInterface;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.Toast;

import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.TrackSelectionOverride;
import androidx.media3.common.TrackSelectionParameters;
import androidx.media3.common.Tracks;
import androidx.media3.common.VideoSize;
import androidx.media3.common.text.Cue;
import androidx.media3.common.text.CueGroup;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.datasource.HttpDataSource;
import androidx.media3.exoplayer.DefaultLoadControl;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.SeekParameters;
import androidx.media3.exoplayer.hls.HlsMediaSource;
import androidx.media3.exoplayer.source.MediaSource;
import androidx.media3.exoplayer.source.ProgressiveMediaSource;
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy;
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy;
import androidx.media3.extractor.DefaultExtractorsFactory;
import androidx.media3.extractor.ts.DefaultTsPayloadReaderFactory;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.Locale;

/**
 * NucFlix for Fire TV:
 * - Layer 0: SurfaceView + Media3 ExoPlayer for HLS (.m3u8), MPEG-TS (.ts), MP4 (.mp4) and MKV (.mkv),
 *   with silent live reconnects and retries for busy single-connection lines.
 * - Layer 1: 1920x1080 10-foot Netflix-clone UI (served from https://app.local/index.html) with
 *   transparent pass-through during video playback so the Netflix OSD renders crisply over video.
 * - Background services: XtreamProxy (CORS-free HTTP/HTTPS IPTV API & image proxy),
 *   PhoneHelper (http://<tv-ip>:8765 companion),
 *   and TudumSound (synthesized Netflix "ta-dum" audio).
 */
public class MainActivity extends Activity implements SurfaceHolder.Callback {

    private static final String UI_HOST = "app.local";
    private static final String UI_URL = "https://" + UI_HOST + "/index.html";
    private static final int HELPER_PORT = 8765;

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    // ExoPlayer's application thread: every player call (and listener callback) happens here.
    private final HandlerThread playerThread = new HandlerThread("NucFlixPlayer");
    private Handler player;
    private FrameLayout root;
    private SurfaceView videoSurface;
    private WebView ui;

    private PhoneHelper phoneHelper;

    private static final long START_TIMEOUT_MS = 20_000;
    private static final int MAX_LIVE_RETRIES = 5;
    private static final int MAX_VOD_RETRIES = 3;

    // Player state (player thread only)
    private ExoPlayer exo;
    private volatile String currentVideoUrl;
    private String currentItemId;
    private double pendingSeekSeconds = 0;
    private boolean playerPrepared = false;
    private boolean playerBuffering = false;
    private boolean playerFailed = false;
    private boolean everReady = false;
    private int retries = 0;
    // Scrubbing: the paused player jumps to the nearest keyframe for each preview position, and the rendered
    // frame is copied off the video surface into the thumbnail bubble (player thread only).
    private boolean scrubbing = false;
    private int thumbId = 0;
    private double thumbSec = 0;
    private long lastRetryAt = 0;
    private JSONArray cachedAudioTracks = new JSONArray();
    private JSONArray cachedSubtitleTracks = new JSONArray();
    private volatile int videoW = 0;
    private volatile int videoH = 0;
    private float currentSpeed = 1.0f;
    private volatile String aspectMode = "fit"; // "fit", "fill", "16:9"
    private int selectedAudioTrack = -1;
    private int selectedSubtitleTrack = -1;
    private boolean nativeDialogShowing = false;
    // A D-pad press still being handled by the UI; key repeats that arrive meanwhile are dropped so a
    // held key can't queue up seconds of moves (measured: 20 queued presses took 1.26 s to drain).
    private boolean keyInFlight = false;

    private final Runnable videoTick = new Runnable() {
        @Override
        public void run() {
            if (exo != null && currentVideoUrl != null && !playerFailed) {
                // A stream that has played steadily for 30 s earns a fresh set of silent retries.
                if (retries > 0 && exo.isPlaying() && SystemClock.elapsedRealtime() - lastRetryAt > 30_000) retries = 0;
                if (playerPrepared) emitVideoState("tick", null);
                player.postDelayed(this, 1000);
            }
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN
                | WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        // Remote inspection (chrome://inspect) can read the in-memory IPTV login, so only debug builds allow it.
        WebView.setWebContentsDebuggingEnabled((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0);
        playerThread.start();
        player = new Handler(playerThread.getLooper());

        phoneHelper = new PhoneHelper(HELPER_PORT, new PhoneActions());

        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);

        videoSurface = new SurfaceView(this);
        videoSurface.getHolder().addCallback(this);
        // Keep the surface permanently attached (it sits beneath the opaque UI stage) so it is never
        // destroyed/recreated between streams.
        videoSurface.setVisibility(View.VISIBLE);
        root.addView(videoSurface, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
                Gravity.CENTER));

        createUiWebView();
        setContentView(root);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (ui != null) {
            ui.onResume();
            ui.resumeTimers();
        }
        phoneHelper.start();
    }

    @Override
    protected void onPause() {
        phoneHelper.stop();
        player.post(() -> {
            if (exo != null && exo.isPlaying()) {
                exo.pause();
                emitVideoState("paused", null);
            }
        });
        if (ui != null) {
            ui.onPause();
            ui.pauseTimers();
        }
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        phoneHelper.stop();
        player.post(() -> {
            stopNativePlayer();
            if (exo != null) {
                exo.release();
                exo = null;
            }
        });
        playerThread.quitSafely();
        if (ui != null) {
            ui.destroy();
        }
        super.onDestroy();
    }

    // ------------------------------------------------------------------ WebView UI Setup

    private void createUiWebView() {
        keyInFlight = false;
        // When any accessibility service is enabled (some custom launchers use one), Android reports
        // accessibility as on and Chromium rebuilds its accessibility tree on every DOM change (150-260 ms per
        // tab switch). Chromium only builds that tree once the framework asks for the node provider, and this
        // UI is driven by the D-pad, so never hand one out.
        ui = new WebView(this) {
            @Override
            public AccessibilityNodeProvider getAccessibilityNodeProvider() {
                return null;
            }
        };
        ui.setBackgroundColor(Color.TRANSPARENT);
        WebSettings s = ui.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
        ui.setVerticalScrollBarEnabled(false);
        ui.setHorizontalScrollBarEnabled(false);
        ui.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
        ui.setFocusable(true);
        ui.setFocusableInTouchMode(true);
        ui.addJavascriptInterface(new NucFlixBridge(), "NucFlixNative");
        ui.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                return serveUi(request.getUrl());
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                return !UI_HOST.equals(request.getUrl().getHost());
            }

            @Override
            public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                if (view == ui) {
                    root.removeView(ui);
                    ui.destroy();
                    createUiWebView();
                }
                return true;
            }
        });
        root.addView(ui, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));
        ui.loadUrl(UI_URL);
        ui.requestFocus();
    }

    private WebResourceResponse serveUi(Uri url) {
        if (!UI_HOST.equals(url.getHost())) return null;
        String path = url.getPath() == null ? "/" : url.getPath();

        if (path.equals("/api/xtream")) {
            return XtreamProxy.fetchJson(url.getQueryParameter("url"));
        }
        if (path.equals("/api/img")) {
            int w = 0;
            try {
                String ws = url.getQueryParameter("w");
                if (ws != null) w = Math.min(1600, Math.max(0, Integer.parseInt(ws)));
            } catch (NumberFormatException ignored) {
            }
            return XtreamProxy.fetchImage(url.getQueryParameter("url"), w);
        }
        if (path.equals("/api/session")) {
            try {
                JSONObject s = new JSONObject();
                String ip = wifiAddress();
                if (ip != null) s.put("helperUrl", "http://" + ip + ":" + HELPER_PORT);
                s.put("deviceModel", android.os.Build.MODEL);
                byte[] bytes = s.toString().getBytes(StandardCharsets.UTF_8);
                return new WebResourceResponse("application/json", "utf-8", 200, "OK",
                        XtreamProxy.corsHeaders(), new ByteArrayInputStream(bytes));
            } catch (Exception e) {
                return XtreamProxy.errorJson(500, "Session error");
            }
        }

        if (path.equals("/")) path = "/index.html";
        if (path.contains("..")) return XtreamProxy.errorJson(404, "Not found");
        try {
            InputStream in = getAssets().open("web" + path);
            return new WebResourceResponse(mimeType(path), "utf-8", 200, "OK", XtreamProxy.corsHeaders(), in);
        } catch (IOException e) {
            return XtreamProxy.errorJson(404, "Not found: " + path);
        }
    }

    private static String mimeType(String path) {
        if (path.endsWith(".html")) return "text/html";
        if (path.endsWith(".js")) return "text/javascript";
        if (path.endsWith(".css")) return "text/css";
        if (path.endsWith(".svg")) return "image/svg+xml";
        if (path.endsWith(".png")) return "image/png";
        if (path.endsWith(".json")) return "application/json";
        if (path.endsWith(".ttf")) return "font/ttf";
        return "application/octet-stream";
    }

    // ------------------------------------------------------------------ Remote Key Routing

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (nativeDialogShowing) {
            return super.dispatchKeyEvent(event);
        }
        int code = event.getKeyCode();
        if (code == KeyEvent.KEYCODE_VOLUME_UP
                || code == KeyEvent.KEYCODE_VOLUME_DOWN
                || code == KeyEvent.KEYCODE_VOLUME_MUTE) {
            return super.dispatchKeyEvent(event);
        }
        if (event.getAction() == KeyEvent.ACTION_DOWN) {
            String keyName = mapKeyCode(code);
            if (keyName != null) {
                if (event.getRepeatCount() > 0 && keyInFlight) return true;
                if (ui != null) {
                    keyInFlight = true;
                    ui.evaluateJavascript("window.App && App.onRemoteKey(" + JSONObject.quote(keyName) + ")",
                            v -> keyInFlight = false);
                }
                return true;
            }
        } else if (event.getAction() == KeyEvent.ACTION_UP) {
            if (mapKeyCode(code) != null) {
                return true;
            }
        }
        return super.dispatchKeyEvent(event);
    }

    private static String mapKeyCode(int code) {
        switch (code) {
            case KeyEvent.KEYCODE_DPAD_UP: return "UP";
            case KeyEvent.KEYCODE_DPAD_DOWN: return "DOWN";
            case KeyEvent.KEYCODE_DPAD_LEFT: return "LEFT";
            case KeyEvent.KEYCODE_DPAD_RIGHT: return "RIGHT";
            case KeyEvent.KEYCODE_DPAD_CENTER:
            case KeyEvent.KEYCODE_ENTER:
            case KeyEvent.KEYCODE_NUMPAD_ENTER:
            case KeyEvent.KEYCODE_BUTTON_A: return "SELECT";
            case KeyEvent.KEYCODE_BACK:
            case KeyEvent.KEYCODE_ESCAPE:
            case KeyEvent.KEYCODE_BUTTON_B: return "BACK";
            case KeyEvent.KEYCODE_MENU:
            case KeyEvent.KEYCODE_BUTTON_Y: return "MENU";
            case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE: return "PLAY_PAUSE";
            case KeyEvent.KEYCODE_MEDIA_PLAY: return "PLAY";
            case KeyEvent.KEYCODE_MEDIA_PAUSE: return "PAUSE";
            case KeyEvent.KEYCODE_MEDIA_FAST_FORWARD:
            case KeyEvent.KEYCODE_BUTTON_R1: return "FF";
            case KeyEvent.KEYCODE_MEDIA_REWIND:
            case KeyEvent.KEYCODE_BUTTON_L1: return "REW";
            case KeyEvent.KEYCODE_CHANNEL_UP:
            case KeyEvent.KEYCODE_PAGE_UP: return "CH_UP";
            case KeyEvent.KEYCODE_CHANNEL_DOWN:
            case KeyEvent.KEYCODE_PAGE_DOWN: return "CH_DOWN";
            default: return null;
        }
    }

    // ------------------------------------------------------------------ ExoPlayer (Media3)

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        player.post(() -> {
            if (exo != null) exo.setVideoSurfaceHolder(holder);
        });
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        player.post(() -> {
            if (exo != null) exo.clearVideoSurfaceHolder(holder);
        });
    }

    // The methods below run on the player thread (ExoPlayer's application looper).

    private ExoPlayer exoPlayer() {
        if (exo != null) return exo;
        DefaultRenderersFactory renderers = new DefaultRenderersFactory(this)
                .setEnableDecoderFallback(true)
                .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF);
        // IPTV providers burst several seconds ahead and then send in real time, so start quickly but
        // wait for a real cushion after a stall (resuming on almost nothing just stalls again).
        // The byte cap keeps 4K/HEVC buffers sane on a 1.7 GB Fire TV.
        DefaultLoadControl load = new DefaultLoadControl.Builder()
                .setBufferDurationsMs(15_000, 40_000, 2_000, 5_000)
                .setTargetBufferBytes(48 * 1024 * 1024)
                .setPrioritizeTimeOverSizeThresholds(false)
                .build();
        exo = new ExoPlayer.Builder(this, renderers)
                .setLooper(playerThread.getLooper())
                .setLoadControl(load)
                .build();
        exo.setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(), false);
        exo.addListener(new ExoListener());
        if (videoSurface != null) exo.setVideoSurfaceHolder(videoSurface.getHolder());
        return exo;
    }

    private void startNativePlayer(String url, String itemId, double resumeSec) {
        stopNativePlayer();
        currentVideoUrl = url;
        currentItemId = itemId;
        pendingSeekSeconds = resumeSec;
        currentSpeed = 1.0f;
        retries = 0;
        prepareCurrent(resumeSec, false, "loading");
    }

    private boolean isLive() {
        return currentItemId != null && currentItemId.startsWith("live-");
    }

    /**
     * (Re)builds the media source for the current URL and prepares it at {@code positionSec}. Used for the
     * first start, silent retries ({@code keepState}: keep tracks / video size) and resuming after a scrub.
     */
    private void prepareCurrent(double positionSec, boolean keepState, String event) {
        if (currentVideoUrl == null) return;
        ExoPlayer p = exoPlayer();
        playerPrepared = false;
        playerFailed = false;
        playerBuffering = true;
        everReady = keepState && everReady;
        if (!keepState) {
            cachedAudioTracks = new JSONArray();
            cachedSubtitleTracks = new JSONArray();
            videoW = 0;
            videoH = 0;
        }
        emitVideoState(event, null);
        try {
            p.setMediaSource(mediaSource(currentVideoUrl));
            if (positionSec > 1.0 && !isLive()) p.seekTo((long) (positionSec * 1000));
            p.setPlaybackSpeed(currentSpeed);
            p.setPlayWhenReady(true);
            p.prepare();
        } catch (Exception e) {
            fail("Couldn't open this stream (" + e.getClass().getSimpleName() + ").");
            return;
        }
        player.removeCallbacks(videoTick);
        player.postDelayed(videoTick, 1000);
        player.removeCallbacks(startWatchdog);
        player.postDelayed(startWatchdog, START_TIMEOUT_MS);
    }

    private MediaSource mediaSource(String url) {
        DefaultHttpDataSource.Factory http = new DefaultHttpDataSource.Factory()
                .setUserAgent(XtreamProxy.USER_AGENT)
                .setAllowCrossProtocolRedirects(true)
                .setConnectTimeoutMs(10_000)
                .setReadTimeoutMs(15_000);
        MediaItem item = MediaItem.fromUri(Uri.parse(url));
        if (url.toLowerCase(Locale.US).contains(".m3u8")) {
            return new HlsMediaSource.Factory(http)
                    .setAllowChunklessPreparation(true)
                    .setLoadErrorHandlingPolicy(RETRY_POLICY)
                    .createMediaSource(item);
        }
        // Many IPTV TS feeds start mid-GOP or without IDR frames; accept any keyframe so they start.
        DefaultExtractorsFactory extractors = new DefaultExtractorsFactory()
                .setTsExtractorFlags(DefaultTsPayloadReaderFactory.FLAG_ALLOW_NON_IDR_KEYFRAMES
                        | DefaultTsPayloadReaderFactory.FLAG_DETECT_ACCESS_UNITS)
                .setConstantBitrateSeekingEnabled(true);
        // Live TS goes through the timestamp re-baser (repairs feeds with audio hours off the video clock).
        DataSource.Factory source = isLive() ? () -> new TsRebaseDataSource(http.createDataSource()) : http;
        return new ProgressiveMediaSource.Factory(source, extractors)
                .setLoadErrorHandlingPolicy(RETRY_POLICY)
                .createMediaSource(item);
    }

    /**
     * Single-connection IPTV lines briefly reject a new connection while the previous one is still being
     * torn down (403 / 458 / 509 / 884 / 5xx), so retry those a few times instead of failing the stream.
     */
    private static final LoadErrorHandlingPolicy RETRY_POLICY = new DefaultLoadErrorHandlingPolicy(6) {
        @Override
        public long getRetryDelayMsFor(LoadErrorInfo info) {
            if (info.exception instanceof HttpDataSource.InvalidResponseCodeException) {
                int code = ((HttpDataSource.InvalidResponseCodeException) info.exception).responseCode;
                boolean busy = code == 403 || code == 429 || code == 458 || code == 509 || code == 884 || code >= 500;
                return busy && info.errorCount <= 4 ? 800L * info.errorCount : C.TIME_UNSET;
            }
            return super.getRetryDelayMsFor(info);
        }
    };

    // Some provider feeds never become playable (e.g. audio timestamps hours ahead of video, seen on live
    // channels here): retry once, then say so instead of reconnecting for minutes.
    private final Runnable startWatchdog = () -> {
        if (exo == null || currentVideoUrl == null || everReady) return;
        String msg = videoW > 0
                ? "This stream's picture arrived but it never became playable — the provider's feed is likely broken. Try Open in VLC."
                : "This stream didn't start in time.";
        if (retries >= 1) fail(msg);
        else retryOrFail(msg);
    };

    /** Live streams reconnect silently (the provider dropped or stalled); VOD resumes where it was. */
    private void retryOrFail(String message) {
        int max = isLive() ? MAX_LIVE_RETRIES : MAX_VOD_RETRIES;
        if (currentVideoUrl != null && retries < max) {
            retries++;
            lastRetryAt = SystemClock.elapsedRealtime();
            double cur = exo == null ? 0 : exo.getCurrentPosition() / 1000.0;
            double pos = isLive() ? 0 : (cur > 1 ? cur : pendingSeekSeconds);
            if (exo != null) exo.stop();
            String url = currentVideoUrl;
            playerBuffering = true;
            emitVideoState("reconnecting", null);
            player.postDelayed(() -> {
                if (url.equals(currentVideoUrl)) prepareCurrent(pos, true, "reconnecting");
            }, 700L * retries);
            return;
        }
        fail(message);
    }

    private void fail(String message) {
        playerFailed = true;
        playerPrepared = false;
        playerBuffering = false;
        player.removeCallbacks(videoTick);
        player.removeCallbacks(startWatchdog);
        if (exo != null) exo.stop(); // free the provider connection so a retry (or VLC) can use the line
        emitVideoState("error", message);
    }

    private static boolean retryable(PlaybackException e) {
        switch (e.errorCode) {
            case PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW:
            case PlaybackException.ERROR_CODE_IO_UNSPECIFIED:
            case PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED:
            case PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT:
            case PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE:
            case PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED:
            case PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED:
            case PlaybackException.ERROR_CODE_DECODING_FAILED:
                return true;
            case PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS:
                int code = httpCode(e);
                return code != 401 && code != 404;
            default:
                return false;
        }
    }

    private static int httpCode(PlaybackException e) {
        Throwable c = e.getCause();
        return c instanceof HttpDataSource.InvalidResponseCodeException
                ? ((HttpDataSource.InvalidResponseCodeException) c).responseCode : 0;
    }

    private String friendlyError(PlaybackException e) {
        int code = httpCode(e);
        if (code == 401 || code == 403) {
            return "The provider refused this stream (HTTP " + code + "). The line may be in use on another device.";
        }
        if (code == 404) {
            return isLive() ? "This channel is offline at the provider right now." : "The provider doesn't have this title (HTTP 404).";
        }
        if (code == 458 || code == 509 || code == 884) {
            return "All connections on this line are in use (HTTP " + code + "). Stop playback on other devices and try again.";
        }
        if (code > 0) return "The provider returned HTTP " + code + " for this stream.";
        switch (e.errorCode) {
            case PlaybackException.ERROR_CODE_DECODER_INIT_FAILED:
            case PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES:
            case PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED:
                return "This Fire TV can't decode this stream's video or audio format.";
            case PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED:
                return "This stream's container format isn't supported.";
            case PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED:
            case PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT:
                return "Couldn't reach the provider's stream server.";
            default:
                return isLive() && !everReady
                        ? "This channel isn't sending a picture right now — it may be off air."
                        : "Couldn't play this stream (" + e.getErrorCodeName() + ").";
        }
    }

    private final class ExoListener implements Player.Listener {
        @Override
        public void onPlaybackStateChanged(int state) {
            if (state == Player.STATE_BUFFERING) {
                playerBuffering = true;
                emitVideoState("buffering", null);
            } else if (state == Player.STATE_READY) {
                playerBuffering = false;
                playerPrepared = true;
                if (!everReady) {
                    everReady = true;
                    player.removeCallbacks(startWatchdog);
                    mainHandler.post(MainActivity.this::applyAspectMode);
                }
                emitVideoState(exo.isPlaying() ? "playing" : "paused", null);
            } else if (state == Player.STATE_ENDED) {
                if (isLive()) {
                    // A live TS feed "ends" when the provider closes the connection: reconnect.
                    retryOrFail("The channel stopped sending video.");
                } else {
                    player.removeCallbacks(videoTick);
                    emitVideoState("ended", null);
                }
            }
        }

        @Override
        public void onIsPlayingChanged(boolean playing) {
            if (exo.getPlaybackState() == Player.STATE_READY) {
                emitVideoState(playing ? "playing" : "paused", null);
            }
        }

        @Override
        public void onPlayerError(PlaybackException error) {
            if (currentVideoUrl == null) return;
            if (retryable(error)) retryOrFail(friendlyError(error));
            else fail(friendlyError(error));
        }

        @Override
        public void onRenderedFirstFrame() {
            if (scrubbing && thumbId > 0) captureThumb(thumbId, thumbSec);
        }

        @Override
        public void onVideoSizeChanged(VideoSize size) {
            if (size.width <= 0 || size.height <= 0) return;
            videoW = Math.round(size.width * (size.pixelWidthHeightRatio > 0 ? size.pixelWidthHeightRatio : 1f));
            videoH = size.height;
            mainHandler.post(MainActivity.this::applyAspectMode);
        }

        @Override
        public void onTracksChanged(Tracks tracks) {
            refreshTracks(tracks);
            emitVideoState("track", null);
        }

        @Override
        public void onCues(CueGroup cueGroup) {
            StringBuilder sb = new StringBuilder();
            for (Cue c : cueGroup.cues) {
                if (c.text == null) continue;
                if (sb.length() > 0) sb.append('\n');
                sb.append(c.text);
            }
            evalJs("window.App && App.onNativeCues && App.onNativeCues(" + JSONObject.quote(sb.toString()) + ")");
        }
    }

    /** Copies the frame currently on the video surface into a small JPEG for the scrub bubble. */
    private void captureThumb(int id, double sec) {
        if (videoSurface == null || !videoSurface.getHolder().getSurface().isValid()) return;
        int w = 384;
        int h = videoW > 0 && videoH > 0 ? Math.max(1, Math.round(w * videoH / (float) videoW)) : 216;
        Bitmap bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        PixelCopy.request(videoSurface, bmp, result -> {
            String dataUrl = "";
            if (result == PixelCopy.SUCCESS && !isBlack(bmp)) {
                ByteArrayOutputStream out = new ByteArrayOutputStream(24 * 1024);
                bmp.compress(Bitmap.CompressFormat.JPEG, 75, out);
                dataUrl = "data:image/jpeg;base64," + Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP);
            }
            bmp.recycle();
            evalJs("window.App && App.onThumb && App.onThumb(" + id + "," + sec + "," + JSONObject.quote(dataUrl) + ")");
        }, player);
    }

    /**
     * Copies the frame on screen into a JPEG for the AI checks (credits, intro, dead channel) and hands it to
     * App.onFrame(id, base64, black). Black frames are sent too: "black screen" is one of the answers.
     */
    private void captureFrame(int id, int width) {
        if (videoSurface == null || !videoSurface.getHolder().getSurface().isValid() || exo == null) {
            evalJs("window.App && App.onFrame && App.onFrame(" + id + ",'',false)");
            return;
        }
        int w = Math.max(160, Math.min(width, 768));
        int h = videoW > 0 && videoH > 0 ? Math.max(1, Math.round(w * videoH / (float) videoW)) : Math.round(w * 9 / 16f);
        Bitmap bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
        PixelCopy.request(videoSurface, bmp, result -> {
            String b64 = "";
            boolean black = false;
            if (result == PixelCopy.SUCCESS) {
                black = isBlack(bmp);
                ByteArrayOutputStream out = new ByteArrayOutputStream(48 * 1024);
                bmp.compress(Bitmap.CompressFormat.JPEG, 72, out);
                b64 = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP);
            }
            bmp.recycle();
            evalJs("window.App && App.onFrame && App.onFrame(" + id + "," + JSONObject.quote(b64) + "," + black + ")");
        }, player);
    }

    /** True when a sparse pixel sample is all (near) black, i.e. nothing was copied. */
    private static boolean isBlack(Bitmap b) {
        for (int y = b.getHeight() / 8; y < b.getHeight(); y += Math.max(1, b.getHeight() / 8)) {
            for (int x = b.getWidth() / 8; x < b.getWidth(); x += Math.max(1, b.getWidth() / 8)) {
                int c = b.getPixel(x, y);
                if (((c >> 16) & 0xff) + ((c >> 8) & 0xff) + (c & 0xff) > 30) return false;
            }
        }
        return true;
    }

    private void stopNativePlayer() {
        scrubbing = false;
        thumbId = 0;
        player.removeCallbacks(videoTick);
        player.removeCallbacks(startWatchdog);
        currentVideoUrl = null;
        currentItemId = null;
        playerPrepared = false;
        playerFailed = false;
        playerBuffering = false;
        everReady = false;
        if (exo != null) {
            exo.stop();
            exo.clearMediaItems();
        }
        evalJs("window.App && App.onNativeCues && App.onNativeCues('')");
        mainHandler.post(() -> {
            if (videoSurface != null) {
                videoSurface.setLayoutParams(new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT, Gravity.CENTER));
            }
        });
    }

    private void applyAspectMode() {
        if (videoSurface == null || root == null) return;
        int rw = root.getWidth();
        int rh = root.getHeight();
        if (rw <= 0 || rh <= 0) return;

        int targetW = rw;
        int targetH = rh;
        if ("16:9".equals(aspectMode)) {
            float scale = Math.min(rw / 16f, rh / 9f);
            targetW = Math.round(16f * scale);
            targetH = Math.round(9f * scale);
        } else if ("fill".equals(aspectMode) && videoW > 0 && videoH > 0) {
            float scale = Math.max(rw / (float) videoW, rh / (float) videoH);
            targetW = Math.round(videoW * scale);
            targetH = Math.round(videoH * scale);
        } else if (videoW > 0 && videoH > 0) {
            float scale = Math.min(rw / (float) videoW, rh / (float) videoH);
            targetW = Math.round(videoW * scale);
            targetH = Math.round(videoH * scale);
        }
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(targetW, targetH, Gravity.CENTER);
        videoSurface.setLayoutParams(lp);
    }

    /** Track index sent to the UI = group * 1000 + track, so it can be mapped back to an override. */
    private void refreshTracks(Tracks tracks) {
        JSONArray audioArr = new JSONArray();
        JSONArray subArr = new JSONArray();
        selectedAudioTrack = -1;
        selectedSubtitleTrack = -1;
        try {
            int n = 0;
            for (int g = 0; g < tracks.getGroups().size(); g++) {
                Tracks.Group group = tracks.getGroups().get(g);
                int type = group.getType();
                if (type != C.TRACK_TYPE_AUDIO && type != C.TRACK_TYPE_TEXT) continue;
                for (int t = 0; t < group.length; t++) {
                    if (!group.isTrackSupported(t)) continue;
                    Format f = group.getTrackFormat(t);
                    n++;
                    int index = g * 1000 + t;
                    JSONObject o = new JSONObject().put("index", index).put("name", trackName(f, n));
                    if (type == C.TRACK_TYPE_AUDIO) {
                        audioArr.put(o);
                        if (group.isTrackSelected(t)) selectedAudioTrack = index;
                    } else {
                        subArr.put(o);
                        if (group.isTrackSelected(t)) selectedSubtitleTrack = index;
                    }
                }
            }
        } catch (Exception ignored) {
        }
        cachedAudioTracks = audioArr;
        cachedSubtitleTracks = subArr;
    }

    private static String trackName(Format f, int n) {
        String lang = f.language;
        String name;
        if (f.label != null && !f.label.isEmpty()) {
            name = f.label;
        } else if (lang == null || lang.isEmpty() || "und".equals(lang)) {
            name = "Track " + n;
        } else {
            String disp = new Locale(lang).getDisplayLanguage(Locale.ENGLISH);
            name = disp != null && !disp.isEmpty() ? disp : lang.toUpperCase(Locale.US);
        }
        if (f.channelCount == 6) name += " 5.1";
        else if (f.channelCount == 8) name += " 7.1";
        return name;
    }

    private void emitVideoState(String event, String errorMsg) {
        try {
            boolean playing = false;
            double pos = 0;
            double dur = 0;
            if (exo != null && currentVideoUrl != null && !playerFailed) {
                playing = exo.isPlaying();
                pos = Math.max(0, exo.getCurrentPosition()) / 1000.0;
                long d = exo.getDuration();
                dur = d != C.TIME_UNSET && d > 0 && !isLive() ? d / 1000.0 : 0;
            }
            JSONObject s = new JSONObject();
            s.put("event", event);
            // Lets the UI drop late updates from the previous item (a stale "near the end" tick from the last
            // episode used to trigger the next-episode countdown again and skip an episode).
            s.put("itemId", currentItemId == null ? "" : currentItemId);
            s.put("playing", playing);
            s.put("buffering", playerBuffering);
            s.put("position", pos);
            s.put("duration", dur);
            s.put("videoWidth", videoW);
            s.put("videoHeight", videoH);
            s.put("speed", currentSpeed);
            s.put("aspectMode", aspectMode);
            s.put("audioTracks", cachedAudioTracks);
            s.put("subtitleTracks", cachedSubtitleTracks);
            s.put("selectedAudioTrack", selectedAudioTrack);
            s.put("selectedSubtitleTrack", selectedSubtitleTrack);
            if (errorMsg != null) s.put("error", errorMsg);
            evalJs("window.App && App.onNativeVideoState(" + s.toString() + ")");
        } catch (Exception ignored) {
        }
    }

    // ------------------------------------------------------------------ JavaScript Bridge

    private class NucFlixBridge {
        @JavascriptInterface
        public void playTudum() {
            TudumSound.play();
        }

        @JavascriptInterface
        public void startVideo(String url, String itemId, double resumeSeconds) {
            player.post(() -> startNativePlayer(url, itemId, resumeSeconds));
        }

        @JavascriptInterface
        public void stopVideo() {
            player.post(MainActivity.this::stopNativePlayer);
        }

        @JavascriptInterface
        public void togglePause() {
            player.post(() -> {
                if (exo == null || !playerPrepared || playerFailed) return;
                if (exo.getPlayWhenReady()) {
                    exo.pause();
                    emitVideoState("paused", null);
                } else {
                    exo.play();
                    emitVideoState("playing", null);
                }
            });
        }

        @JavascriptInterface
        public void seekTo(double seconds) {
            player.post(() -> {
                if (exo == null || !playerPrepared || playerFailed || isLive()) return;
                long dur = exo.getDuration();
                double max = dur != C.TIME_UNSET && dur > 0 ? dur / 1000.0 - 0.5 : seconds;
                exo.seekTo((long) (Math.max(0, Math.min(max, seconds)) * 1000));
                emitVideoState("seek", null);
            });
        }

        /**
         * Timeline scrubbing. The player stays paused and seeks to the nearest keyframe for every preview
         * position (one connection, which is all the line allows); each rendered frame is copied into the
         * thumbnail bubble. {@link #endScrub} seeks exactly to the chosen position and resumes.
         */
        @JavascriptInterface
        public void beginScrub() {
            player.post(() -> {
                if (exo == null || currentVideoUrl == null || isLive() || !playerPrepared || playerFailed) return;
                scrubbing = true;
                thumbId = 0;
                exo.pause();
                exo.setSeekParameters(SeekParameters.CLOSEST_SYNC);
            });
        }

        @JavascriptInterface
        public void captureFrame(int id, int width) {
            player.post(() -> MainActivity.this.captureFrame(id, width));
        }

        @JavascriptInterface
        public void requestThumb(double seconds, int id) {
            player.post(() -> {
                if (!scrubbing || exo == null) return;
                thumbId = id;
                thumbSec = seconds;
                exo.seekTo((long) (Math.max(0, seconds) * 1000));
            });
        }

        @JavascriptInterface
        public void endScrub(double seconds) {
            player.post(() -> {
                if (!scrubbing || exo == null) return;
                scrubbing = false;
                thumbId = 0;
                exo.setSeekParameters(SeekParameters.DEFAULT);
                exo.seekTo((long) (Math.max(0, seconds) * 1000));
                exo.play();
                emitVideoState("seek", null);
            });
        }

        @JavascriptInterface
        public void setSpeed(float speed) {
            player.post(() -> {
                currentSpeed = speed;
                if (exo == null || playerFailed) return;
                exo.setPlaybackSpeed(speed);
                emitVideoState("speed", null);
            });
        }

        @JavascriptInterface
        public void setAspectMode(String mode) {
            runOnUiThread(() -> {
                aspectMode = mode != null ? mode : "fit";
                applyAspectMode();
                player.post(() -> emitVideoState("aspect", null));
            });
        }

        /** {@code trackIndex} is group * 1000 + track (see refreshTracks); -1 turns subtitles off. */
        @JavascriptInterface
        public void selectTrack(int trackIndex, boolean isAudio) {
            player.post(() -> {
                if (exo == null || !playerPrepared || playerFailed) return;
                int type = isAudio ? C.TRACK_TYPE_AUDIO : C.TRACK_TYPE_TEXT;
                TrackSelectionParameters.Builder b = exo.getTrackSelectionParameters().buildUpon();
                if (trackIndex < 0) {
                    b.setTrackTypeDisabled(type, true);
                } else {
                    int g = trackIndex / 1000;
                    int t = trackIndex % 1000;
                    Tracks tracks = exo.getCurrentTracks();
                    if (g >= tracks.getGroups().size()) return;
                    b.setTrackTypeDisabled(type, false)
                            .setOverrideForType(new TrackSelectionOverride(
                                    tracks.getGroups().get(g).getMediaTrackGroup(), t));
                }
                exo.setTrackSelectionParameters(b.build());
            });
        }

        @JavascriptInterface
        public void openInVlc(String url, String title) {
            runOnUiThread(() -> {
                try {
                    Intent vlc = new Intent(Intent.ACTION_VIEW);
                    vlc.setPackage("org.videolan.vlc");
                    vlc.setDataAndTypeAndNormalize(Uri.parse(url), "video/*");
                    vlc.putExtra("title", title);
                    startActivity(vlc);
                } catch (Exception e) {
                    try {
                        Intent generic = new Intent(Intent.ACTION_VIEW);
                        generic.setDataAndTypeAndNormalize(Uri.parse(url), "video/*");
                        startActivity(generic);
                    } catch (Exception ex) {
                        Toast.makeText(MainActivity.this,
                                "VLC for Fire TV is not installed. Using built-in NucFlix player.",
                                Toast.LENGTH_LONG).show();
                    }
                }
            });
        }

        @JavascriptInterface
        public void promptInput(String label, String currentValue, String fieldKey) {
            runOnUiThread(() -> showNativeInputDialog(label, currentValue, fieldKey));
        }

        @JavascriptInterface
        public void exitApp() {
            runOnUiThread(MainActivity.this::finish);
        }
    }

    private void showNativeInputDialog(String label, String currentValue, String fieldKey) {
        nativeDialogShowing = true;
        EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setText(currentValue != null ? currentValue : "");
        input.setSelection(input.getText().length());
        input.setImeOptions(EditorInfo.IME_ACTION_DONE | EditorInfo.IME_FLAG_NO_FULLSCREEN);
        input.setInputType(InputType.TYPE_CLASS_TEXT);

        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle(label)
                .setView(input)
                .setPositiveButton("Done", (d, w) -> {
                    String val = input.getText().toString();
                    evalJs("window.App && App.onNativeFieldInput("
                            + JSONObject.quote(fieldKey) + ","
                            + JSONObject.quote(val) + ")");
                })
                .setNegativeButton("Cancel", null)
                .create();
        dialog.setOnDismissListener(d -> {
            nativeDialogShowing = false;
            if (ui != null) ui.requestFocus();
        });
        dialog.show();
        input.requestFocus();
    }

    // ------------------------------------------------------------------ Phone Helper Callbacks

    private class PhoneActions implements PhoneHelper.Actions {
        @Override
        public void search(String query) {
            runOnUiThread(() -> evalJs("window.App && App.onPhoneSearch(" + JSONObject.quote(query) + ")"));
        }

        @Override
        public void typeText(String text) {
            runOnUiThread(() -> evalJs("window.App && App.onPhoneType(" + JSONObject.quote(text) + ")"));
        }
    }

    private void evalJs(String script) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post(() -> evalJs(script));
            return;
        }
        if (ui != null) {
            ui.evaluateJavascript(script, null);
        }
    }

    private static String wifiAddress() {
        try {
            for (NetworkInterface nif : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!nif.isUp() || nif.isLoopback()) continue;
                for (InetAddress addr : Collections.list(nif.getInetAddresses())) {
                    if (addr instanceof Inet4Address && addr.isSiteLocalAddress()) {
                        return addr.getHostAddress();
                    }
                }
            }
        } catch (Exception ignored) {
        }
        return null;
    }
}
