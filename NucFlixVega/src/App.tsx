import {WebView} from '@amazon-devices/webview';
import * as React from 'react';
import {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {View, StyleSheet} from 'react-native';
import {KeplerVideoView, VideoPlayer} from '@amazon-devices/react-native-w3cmedia';
import {AspectMode, NucFlixPlayer} from './NativePlayer';
import {
  useHideSplashScreenCallback,
  useKeplerBackHandler,
  usePreventHideSplashScreen,
} from '@amazon-devices/react-native-kepler';
import {
  SslErrorData,
  WebViewErrorEvent,
  WebViewHttpErrorEvent,
  WebViewMessageEvent,
} from '@amazon-devices/webview/dist/types/WebViewTypes';

// The shared Fire TV web UI, copied in by scripts/sync-web.sh with vega-shim.js loaded first.
const UI_URL = 'file:///pkg/assets/web/index.html';

// Same as the Android build (XtreamProxy.USER_AGENT): some IPTV panels only answer known player apps.
const USER_AGENT = 'IPTVSmartersPlayer/3.0 (iOS; iPhone; Scale/3.00)';

type BridgeMessage =
  | {type: 'xtream'; id: number; url: string | null}
  | {type: 'probe'; id: number; url: string}
  | {type: 'exit'}
  | {type: 'video'; op: string; args: any[]}
  | {type: 'log'; level: 'info' | 'error'; msg: string};

// Debug: a URL here plays instead of every movie/episode (e.g. a public sample such as
// https://download.blender.org/durian/trailer/sintel_trailer-720p.mp4) to test the video pipeline
// when the provider won't serve this TV. Empty string = normal playback.
const TEST_STREAM_URL = '';

// KeplerVideoView's scaling for the UI's aspect modes (Android: applyAspectMode).
const SCALING: Record<AspectMode, 'fit' | 'fill' | 'strech'> = {fit: 'fit', fill: 'fill', '16:9': 'strech'};

/**
 * Debug: the line's own view of itself (player_api.php user_info) for the stream URL's credentials —
 * connections in use vs allowed, status and allowed formats. Never includes the credentials.
 */
async function lineStatus(streamUrl: string): Promise<string> {
  const m = /^(https?:\/\/[^/]+)\/(?:movie\/|series\/|live\/)?([^/]+)\/([^/]+)\/[^/]+$/.exec(streamUrl);
  if (!m) {
    return 'line: unrecognised stream URL';
  }
  try {
    const resp = await fetch(
      `${m[1]}/player_api.php?username=${encodeURIComponent(m[2])}&password=${encodeURIComponent(m[3])}`,
      {headers: {'User-Agent': USER_AGENT, Accept: 'application/json'}},
    );
    const u = (await resp.json())?.user_info || {};
    return (
      `line: status=${u.status} active_cons=${u.active_cons} max=${u.max_connections} ` +
      `trial=${u.is_trial} formats=${JSON.stringify(u.allowed_output_formats)} msg=${u.message || ''}`
    );
  } catch (e) {
    return `line: lookup failed ${e instanceof Error ? e.message : String(e)}`;
  }
}

/**
 * Debug: asks a stream URL for its response headers from the app (outside the WebView) and drops the
 * body, so it shows whether the server answers this TV at all — status, type, size and redirect host.
 */
async function probeStream(url: string): Promise<string> {
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), 15000);
  const started = Date.now();
  try {
    const resp = await fetch(url, {
      headers: {'User-Agent': USER_AGENT},
      signal: abort.signal,
    });
    const ms = Date.now() - started;
    const host = (/^https?:\/\/([^/?#]+)/.exec(resp.url || '') || [])[1] || '?';
    let result =
      `HTTP ${resp.status} in ${ms}ms type=${resp.headers.get('content-type') || '?'} ` +
      `len=${resp.headers.get('content-length') || '?'} from=${host}`;
    if (resp.status < 200 || resp.status >= 300) {
      // Error pages are small; their text usually says why (blocked region, too many connections…).
      const text = (await resp.text())
        .replace(/<(script|style)[\s\S]*?<\/\1>/gi, ' ')
        .replace(/<[^>]+>/g, ' ')
        .replace(/\s+/g, ' ')
        .trim();
      result += ` body="${text.slice(0, 300)}"`;
      result += ' | ' + (await lineStatus(url));
    }
    abort.abort(); // don't download the stream
    return result;
  } catch (e) {
    const msg = e instanceof Error ? e.message || e.name : String(e);
    return `failed after ${Date.now() - started}ms: ${msg}`;
  } finally {
    clearTimeout(timer);
  }
}

/** Port of XtreamProxy.fetchJson: returns [status, body] with the same error JSON the web UI expects. */
async function fetchXtream(url: string | null): Promise<[number, string]> {
  const error = (status: number, message: string): [number, string] => [
    status,
    JSON.stringify({ok: false, error: message}),
  ];
  if (!url || !/^https?:\/\//.test(url)) {
    return error(
      400,
      'This IPTV line has an invalid server URL. Fix it in the NucFlix iPhone app (Settings → IPTV Lines).',
    );
  }
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), 45000);
  try {
    const resp = await fetch(url, {
      headers: {'User-Agent': USER_AGENT, Accept: 'application/json, */*'},
      signal: abort.signal,
    });
    const code = resp.status;
    if (code === 401 || code === 403) {
      return error(
        code,
        `Server rejected the credentials (HTTP ${code}). The line may be expired, disabled, or blocked.`,
      );
    }
    if (code === 884) {
      return error(
        code,
        'All connection slots are in use (HTTP 884). Close other devices using this line and try again.',
      );
    }
    if (code < 200 || code >= 300) {
      return error(
        code,
        `Server returned HTTP status ${code}. Check the line's server URL and port in the NucFlix iPhone app.`,
      );
    }
    return [200, await resp.text()];
  } catch (e) {
    const msg = e instanceof Error ? e.message || e.name : String(e);
    return error(502, `Network error connecting to server: ${msg}`);
  } finally {
    clearTimeout(timer);
  }
}

export const App = () => {
  const webRef = useRef<any>(null);
  usePreventHideSplashScreen();
  const hideSplashScreenCallback = useHideSplashScreenCallback();
  const backHandler = useKeplerBackHandler();

  // allowSystemKeyEvents should deliver Back to the page (as Escape), but while a video is loading it
  // reached the system instead and sent the app to the background. Whatever arrives here goes to the UI.
  useEffect(() => {
    const onBack = () => {
      console.info('[native] Back press -> forwarding BACK to the UI');
      webRef.current?.injectJavaScript(
        "window.__nucflixDebug && window.__nucflixDebug('native Back -> BACK'); window.App && App.onRemoteKey('BACK'); true;",
      );
      return true; // handled: don't background the app
    };
    const subs = [
      backHandler.addEventListener('backPress', onBack),
      backHandler.addEventListener('hardwareBackPress', onBack),
    ];
    return () => subs.forEach(s => s.remove());
  }, [backHandler]);

  // Native video layer, drawn behind the (then transparent) WebView like the Android SurfaceView.
  const [video, setVideo] = useState<{player: VideoPlayer | null; aspect: AspectMode}>({
    player: null,
    aspect: 'fit',
  });
  const player = useMemo(
    () =>
      new NucFlixPlayer(USER_AGENT, {
        state: s =>
          webRef.current?.injectJavaScript(
            `window.App && App.onNativeVideoState(${JSON.stringify(s)}); true;`,
          ),
        view: (p, aspect) => setVideo({player: p, aspect}),
        log: m => {
          console.info(`[player] ${m}`);
          webRef.current?.injectJavaScript(
            `window.__nucflixDebug && window.__nucflixDebug(${JSON.stringify('player: ' + m)}); true;`,
          );
        },
      }),
    [],
  );
  useEffect(() => () => void player.stop(), [player]);

  const onVideoCall = useCallback(
    (op: string, a: any[]) => {
      switch (op) {
        case 'start': {
          const itemId = String(a[1] || '');
          const url = TEST_STREAM_URL && !itemId.startsWith('live-') ? TEST_STREAM_URL : String(a[0]);
          player.start(url, itemId, Number(a[2]) || 0);
          break;
        }
        case 'stop':
          player.stop();
          break;
        case 'togglePause':
          player.togglePause();
          break;
        case 'seekTo':
          player.seekTo(Number(a[0]) || 0);
          break;
        case 'setSpeed':
          player.setSpeed(Number(a[0]) || 1);
          break;
        case 'setAspectMode':
          player.setAspect(String(a[0]));
          break;
        case 'selectTrack':
          player.selectTrack(Number(a[0]), !!a[1]);
          break;
        case 'beginScrub':
          player.beginScrub();
          break;
        case 'endScrub':
          player.endScrub(Number(a[0]) || 0);
          break;
      }
    },
    [player],
  );

  const onMessage = useCallback(async (event: WebViewMessageEvent) => {
    let msg: BridgeMessage;
    try {
      msg = JSON.parse(event.nativeEvent.data);
    } catch {
      return;
    }
    if (msg.type === 'video') {
      onVideoCall(msg.op, msg.args || []);
    } else if (msg.type === 'exit') {
      backHandler.exitApp();
    } else if (msg.type === 'log') {
      (msg.level === 'error' ? console.error : console.info)(`[web] ${msg.msg}`);
    } else if (msg.type === 'probe') {
      const result = await probeStream(msg.url);
      webRef.current?.injectJavaScript(
        `window.__nucflixDebug && window.__nucflixDebug(${JSON.stringify('probe: ' + result)}); true;`,
      );
    } else if (msg.type === 'xtream') {
      const [status, body] = await fetchXtream(msg.url);
      webRef.current?.injectJavaScript(
        `window.__nucflixReply(${msg.id}, ${status}, ${JSON.stringify(body)}); true;`,
      );
    }
  }, [backHandler, onVideoCall]);

  return (
    <View style={styles.container}>
      {video.player && (
        <KeplerVideoView
          style={StyleSheet.absoluteFill}
          videoPlayer={video.player}
          showControls={false}
          showCaptions
          scalingmode={SCALING[video.aspect]}
        />
      )}
      <WebView
        ref={webRef}
        style={[styles.webview, video.player ? styles.overVideo : null]}
        allowSystemKeyEvents
        allowsDefaultMediaControl={false}
        domStorageEnabled
        hasTVPreferredFocus
        javaScriptEnabled
        mediaPlaybackRequiresUserAction={false}
        mixedContentMode="always"
        userAgent={USER_AGENT}
        source={{uri: UI_URL}}
        onMessage={onMessage}
        onLoad={() => {
          console.info('NucFlix UI loaded');
          hideSplashScreenCallback();
        }}
        onError={({nativeEvent: {code, url, description}}: WebViewErrorEvent) => {
          console.error(`[onError]: (${code}: ${url}) ${description}`);
        }}
        onHttpError={({
          nativeEvent: {url, statusCode: code, description},
        }: WebViewHttpErrorEvent) => {
          console.error(`[onHttpError]: (${code}: ${url}) ${description}`);
        }}
        onSslError={({code, url, description}: SslErrorData) => {
          console.error(`[onSslError]: (${code}: ${url}) ${description}`);
        }}
      />
    </View>
  );
};

// Styles for layout, which are necessary for proper focus behavior
const styles = StyleSheet.create({
  container: {flex: 1, backgroundColor: '#000000'},
  webview: {...StyleSheet.absoluteFillObject, backgroundColor: '#000000'},
  // During playback the page goes see-through (app.js: #stage.video-passthrough) over the video.
  overVideo: {backgroundColor: 'transparent'},
});
