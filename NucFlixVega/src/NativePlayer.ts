import {VideoPlayer} from '@amazon-devices/react-native-w3cmedia';

/**
 * Vega port of the Android app's ExoPlayer layer (MainActivity: startNativePlayer, retryOrFail, emitVideoState).
 * Plays in URL mode on the W3C VideoPlayer (MKV, MP4 and live MPEG-TS) and reports the same state object the
 * web UI's App.onNativeVideoState expects. Each start or retry gets a fresh VideoPlayer: switching src on a
 * live player isn't reliable, and a new instance also frees the provider's single connection.
 */

const START_TIMEOUT_MS = 20000;
const MAX_LIVE_RETRIES = 5;
const MAX_VOD_RETRIES = 3;

export type AspectMode = 'fit' | 'fill' | '16:9';

type Track = {index: number; name: string};

export type VideoState = {
  event: string;
  itemId: string;
  playing: boolean;
  buffering: boolean;
  position: number;
  duration: number;
  videoWidth: number;
  videoHeight: number;
  speed: number;
  aspectMode: AspectMode;
  audioTracks: Track[];
  subtitleTracks: Track[];
  selectedAudioTrack: number;
  selectedSubtitleTrack: number;
  error?: string;
};

type Listeners = {
  /** State for App.onNativeVideoState. */
  state: (s: VideoState) => void;
  /** The player to render in KeplerVideoView (null: nothing playing) and how to scale it. */
  view: (player: VideoPlayer | null, aspect: AspectMode) => void;
  log: (msg: string) => void;
};

const MEDIA_ERR: Record<number, string> = {1: 'ABORTED', 2: 'NETWORK', 3: 'DECODE', 4: 'SRC_NOT_SUPPORTED'};

const LANGUAGES: Record<string, string> = {
  en: 'English', eng: 'English', hi: 'Hindi', hin: 'Hindi', es: 'Spanish', spa: 'Spanish', fr: 'French',
  fre: 'French', fra: 'French', de: 'German', ger: 'German', deu: 'German', it: 'Italian', ita: 'Italian',
  pt: 'Portuguese', por: 'Portuguese', ar: 'Arabic', ara: 'Arabic', ta: 'Tamil', tam: 'Tamil', te: 'Telugu',
  tel: 'Telugu', ml: 'Malayalam', mal: 'Malayalam', kn: 'Kannada', kan: 'Kannada', bn: 'Bengali', ben: 'Bengali',
  mr: 'Marathi', mar: 'Marathi', gu: 'Gujarati', guj: 'Gujarati', pa: 'Punjabi', pan: 'Punjabi', ur: 'Urdu',
  urd: 'Urdu', ja: 'Japanese', jpn: 'Japanese', ko: 'Korean', kor: 'Korean', zh: 'Chinese', chi: 'Chinese',
  zho: 'Chinese', ru: 'Russian', rus: 'Russian', tr: 'Turkish', tur: 'Turkish', nl: 'Dutch', dut: 'Dutch',
};

function trackName(t: {label?: string; language?: string}, n: number): string {
  if (t.label) {
    return t.label;
  }
  const lang = (t.language || '').toLowerCase();
  if (!lang || lang === 'und') {
    return `Track ${n}`;
  }
  return LANGUAGES[lang] || lang.toUpperCase();
}

/** HTTP failures inside a W3C media error message (GStreamer souphttpsrc), with the Android app's wording. */
function httpReason(detail: string): {code: number; message: (live: boolean) => string} | null {
  const known: [RegExp, number][] = [
    [/Not Found/i, 404],
    [/Forbidden/i, 403],
    [/Unauthorized/i, 401],
    [/Service Unavailable|Bad Gateway|Internal Server Error/i, 503],
  ];
  const numeric = /status (?:code )?(\d{3})|HTTP[ /]\S* (\d{3})|\((\d{3})\)/i.exec(detail);
  let code = numeric ? Number(numeric[1] || numeric[2] || numeric[3]) : 0;
  if (!code) {
    for (const [re, c] of known) {
      if (re.test(detail)) {
        code = c;
        break;
      }
    }
  }
  if (!code) {
    return null;
  }
  return {
    code,
    message: live => {
      if (code === 401 || code === 403) {
        return `The provider refused this stream (HTTP ${code}). The line may be in use on another device.`;
      }
      if (code === 404) {
        return live
          ? 'The provider says this channel isn\'t available (HTTP 404). It may be offline, or blocked for this TV\'s location or VPN.'
          : 'The provider says this title isn\'t available (HTTP 404). It may be missing, or blocked for this TV\'s location or VPN.';
      }
      if (code === 456) {
        return 'The provider is blocking video for this TV\'s location (HTTP 456).';
      }
      if (code === 458 || code === 509 || code === 884) {
        return `All connections on this line are in use (HTTP ${code}). Stop playback on other devices and try again.`;
      }
      return `The provider returned HTTP ${code} for this stream.`;
    },
  };
}

export class NucFlixPlayer {
  private video: VideoPlayer | null = null;
  private url: string | null = null;
  private itemId = '';
  private pendingSeek = 0;
  private speed = 1;
  private aspect: AspectMode = 'fit';
  private retries = 0;
  private lastRetryAt = 0;
  private everReady = false;
  private prepared = false;
  private failed = false;
  private buffering = false;
  private videoW = 0;
  private videoH = 0;
  private audioTracks: Track[] = [];
  private subtitleTracks: Track[] = [];
  private selectedAudio = -1;
  private selectedSubtitle = -1;
  private tick: ReturnType<typeof setInterval> | null = null;
  private watchdog: ReturnType<typeof setTimeout> | null = null;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  // Bumped on every start/stop/retry so a slow initialize() from an older attempt can't take over.
  private generation = 0;

  constructor(private readonly userAgent: string, private readonly on: Listeners) {}

  private get isLive(): boolean {
    return this.itemId.startsWith('live-');
  }

  async start(url: string, itemId: string, resumeSec: number): Promise<void> {
    await this.stop();
    this.url = url;
    this.itemId = itemId;
    this.speed = 1;
    this.retries = 0;
    this.everReady = false;
    this.audioTracks = [];
    this.subtitleTracks = [];
    this.videoW = 0;
    this.videoH = 0;
    await this.prepare(resumeSec, 'loading');
  }

  async stop(): Promise<void> {
    this.generation++;
    this.clearTimers();
    this.url = null;
    this.prepared = false;
    this.failed = false;
    this.buffering = false;
    await this.release();
  }

  togglePause(): void {
    const v = this.video;
    if (!v || !this.prepared || this.failed) {
      return;
    }
    if (v.paused) {
      this.playSafe(v);
      this.emit('playing');
    } else {
      v.pause();
      this.emit('paused');
    }
  }

  seekTo(sec: number): void {
    const v = this.video;
    if (!v || !this.prepared || this.failed || this.isLive) {
      return;
    }
    const max = isFinite(v.duration) && v.duration > 0 ? v.duration - 0.5 : sec;
    v.currentTime = Math.max(0, Math.min(max, sec));
    this.emit('seek');
  }

  setSpeed(speed: number): void {
    this.speed = speed;
    if (this.video && !this.failed) {
      this.video.playbackRate = speed;
      this.emit('speed');
    }
  }

  setAspect(mode: string): void {
    this.aspect = mode === 'fill' || mode === '16:9' ? mode : 'fit';
    this.on.view(this.video, this.aspect);
    this.emit('aspect');
  }

  /** {@code index} is the position in the track list; -1 turns subtitles off. */
  selectTrack(index: number, isAudio: boolean): void {
    const v = this.video as any;
    if (!v || !this.prepared || this.failed) {
      return;
    }
    if (isAudio) {
      const list = v.audioTracks;
      for (let i = 0; i < (list?.length || 0); i++) {
        list[i].enabled = i === index;
      }
    } else {
      const list = v.textTracks;
      for (let i = 0; i < (list?.length || 0); i++) {
        list[i].mode = i === index ? 'showing' : 'disabled';
      }
    }
    this.refreshTracks();
    this.emit('track');
  }

  beginScrub(): void {
    if (this.video && this.prepared && !this.isLive) {
      this.video.pause();
    }
  }

  endScrub(sec: number): void {
    const v = this.video;
    if (!v || !this.prepared || this.isLive) {
      return;
    }
    v.currentTime = Math.max(0, sec);
    this.playSafe(v);
    this.emit('seek');
  }

  // ------------------------------------------------------------------ internals

  private async prepare(positionSec: number, event: string): Promise<void> {
    const gen = ++this.generation;
    this.clearTimers();
    await this.release();
    if (gen !== this.generation || !this.url) {
      return;
    }
    const url = this.url;
    this.prepared = false;
    this.failed = false;
    this.buffering = true;
    this.pendingSeek = positionSec > 1 && !this.isLive ? positionSec : 0;
    this.emit(event);

    const v = new VideoPlayer();
    try {
      await v.initialize();
    } catch (e) {
      this.on.log(`player initialize failed: ${String(e)}`);
      this.fail("The TV's video player didn't start.");
      return;
    }
    if (gen !== this.generation) {
      v.deinitialize().catch(() => {});
      return;
    }
    this.video = v;
    this.listen(v, gen);
    this.on.view(v, this.aspect);
    v.setSrcWithCustomHeaders(url, {'User-Agent': this.userAgent});
    v.playbackRate = this.speed;
    this.playSafe(v);

    let ticks = 0;
    this.tick = setInterval(() => {
      if (!this.video || this.failed) {
        return;
      }
      // A stream that has played steadily for 30 s earns a fresh set of silent retries.
      if (this.retries > 0 && !this.video.paused && Date.now() - this.lastRetryAt > 30000) {
        this.retries = 0;
      }
      if (this.prepared) {
        this.emit('tick');
      }
      if (++ticks % 5 === 0) {
        const v = this.video;
        this.on.log(`tick t=${(v.currentTime || 0).toFixed(1)} paused=${v.paused} buffering=${this.buffering} ${v.videoWidth}x${v.videoHeight} audio=${(v.audioTracks as any)?.length ?? '?'}`);
      }
    }, 1000);
    this.watchdog = setTimeout(() => {
      if (this.everReady || gen !== this.generation) {
        return;
      }
      const msg =
        this.videoW > 0
          ? "This stream's picture arrived but it never became playable — the provider's feed is likely broken."
          : "This stream didn't start in time.";
      if (this.retries >= 1) {
        this.fail(msg);
      } else {
        this.retryOrFail(msg);
      }
    }, START_TIMEOUT_MS);
  }

  private listen(v: VideoPlayer, gen: number): void {
    const mine = (fn: () => void) => () => {
      if (gen === this.generation && this.video === v) {
        fn();
      }
    };
    v.addEventListener('loadedmetadata', mine(() => {
      this.videoW = v.videoWidth || 0;
      this.videoH = v.videoHeight || 0;
      if (this.pendingSeek > 0) {
        v.currentTime = this.pendingSeek;
        this.pendingSeek = 0;
      }
      this.refreshTracks();
      this.on.log(`metadata ${this.videoW}x${this.videoH} dur=${Math.round(v.duration)} audio=${this.audioTracks.length} subs=${this.subtitleTracks.length}`);
      this.emit('track');
    }));
    // Debug: playback events in the log (the TV screen can't be seen from here).
    ['canplay', 'playing', 'pause', 'waiting', 'stalled', 'ended', 'seeked', 'resize'].forEach(ev =>
      v.addEventListener(ev, mine(() =>
        this.on.log(`event ${ev} t=${(v.currentTime || 0).toFixed(1)} ${v.videoWidth}x${v.videoHeight} paused=${v.paused} rs=${v.readyState}`),
      )),
    );
    v.addEventListener('canplay', mine(() => {
      this.prepared = true;
      this.buffering = false;
    }));
    v.addEventListener('playing', mine(() => {
      this.prepared = true;
      this.buffering = false;
      if (!this.everReady) {
        this.everReady = true;
        if (this.watchdog) {
          clearTimeout(this.watchdog);
          this.watchdog = null;
        }
      }
      this.emit('playing');
    }));
    v.addEventListener('pause', mine(() => {
      if (this.prepared) {
        this.emit('paused');
      }
    }));
    v.addEventListener('waiting', mine(() => {
      this.buffering = true;
      this.emit('buffering');
    }));
    v.addEventListener('ended', mine(() => {
      if (this.isLive) {
        // A live TS feed "ends" when the provider closes the connection: reconnect.
        this.retryOrFail('The channel stopped sending video.');
      } else {
        this.emit('ended');
      }
    }));
    v.addEventListener('error', mine(() => {
      const err = v.error;
      const name = err ? MEDIA_ERR[err.code] || String(err.code) : '?';
      const detail = err?.message || '';
      this.on.log(`player error ${name} ${detail.slice(0, 160)}`);
      // GStreamer reports HTTP failures from its source as DECODE errors; the message carries the HTTP reason.
      const http = httpReason(detail);
      if (http) {
        // Like the Android player, a missing title or refused login won't fix itself by retrying.
        if (http.code === 404 || http.code === 401) {
          this.fail(http.message(this.isLive));
        } else {
          this.retryOrFail(http.message(this.isLive));
        }
        return;
      }
      const msg =
        err?.code === 3
          ? this.isLive
            ? 'This channel is sending damaged video right now.'
            : "This Fire TV can't decode this title's video or audio."
          : err?.code === 4
          ? "This stream's format isn't supported on this TV."
          : "Couldn't reach the provider's stream server.";
      this.retryOrFail(msg);
    }));
    const tracksChanged = mine(() => {
      this.refreshTracks();
      this.emit('track');
    });
    (v.audioTracks as any)?.addEventListener?.('addtrack', tracksChanged);
    (v.textTracks as any)?.addEventListener?.('addtrack', tracksChanged);
  }

  /** Live streams reconnect silently (the provider dropped or stalled); VOD resumes where it was. */
  private retryOrFail(message: string): void {
    const max = this.isLive ? MAX_LIVE_RETRIES : MAX_VOD_RETRIES;
    if (!this.url || this.retries >= max) {
      this.fail(message);
      return;
    }
    this.retries++;
    this.lastRetryAt = Date.now();
    const cur = this.video ? this.video.currentTime : 0;
    const pos = this.isLive ? 0 : cur > 1 ? cur : this.pendingSeek;
    const url = this.url;
    this.buffering = true;
    this.emit('reconnecting');
    this.clearTimers();
    this.retryTimer = setTimeout(() => {
      if (url === this.url) {
        this.prepare(pos, 'reconnecting');
      }
    }, 700 * this.retries);
  }

  private fail(message: string): void {
    this.failed = true;
    this.prepared = false;
    this.buffering = false;
    this.clearTimers();
    // Free the provider connection so a retry can use the line.
    this.release().then(() => this.emit('error', message));
  }

  private async release(): Promise<void> {
    const v = this.video;
    if (!v) {
      return;
    }
    this.video = null;
    this.on.view(null, this.aspect);
    try {
      v.pause();
    } catch {}
    try {
      await v.deinitialize();
    } catch (e) {
      this.on.log(`deinitialize: ${String(e)}`);
    }
  }

  private playSafe(v: VideoPlayer): void {
    try {
      const p: any = v.play();
      p?.catch?.((e: any) => this.on.log(`play() rejected: ${String(e)}`));
    } catch (e) {
      this.on.log(`play() threw: ${String(e)}`);
    }
  }

  private refreshTracks(): void {
    const v = this.video as any;
    const audio: Track[] = [];
    const subs: Track[] = [];
    this.selectedAudio = -1;
    this.selectedSubtitle = -1;
    const al = v?.audioTracks;
    for (let i = 0; i < (al?.length || 0); i++) {
      audio.push({index: i, name: trackName(al[i], i + 1)});
      if (al[i].enabled) {
        this.selectedAudio = i;
      }
    }
    const tl = v?.textTracks;
    for (let i = 0; i < (tl?.length || 0); i++) {
      const t = tl[i];
      if (t.kind && t.kind !== 'subtitles' && t.kind !== 'captions') {
        continue;
      }
      subs.push({index: i, name: trackName(t, subs.length + 1)});
      if (t.mode === 'showing') {
        this.selectedSubtitle = i;
      }
    }
    this.audioTracks = audio;
    this.subtitleTracks = subs;
  }

  private clearTimers(): void {
    if (this.tick) {
      clearInterval(this.tick);
      this.tick = null;
    }
    if (this.watchdog) {
      clearTimeout(this.watchdog);
      this.watchdog = null;
    }
    if (this.retryTimer) {
      clearTimeout(this.retryTimer);
      this.retryTimer = null;
    }
  }

  private emit(event: string, error?: string): void {
    const v = this.video;
    const ok = !!v && !!this.url && !this.failed;
    const dur = ok && isFinite(v!.duration) && v!.duration > 0 && !this.isLive ? v!.duration : 0;
    this.on.state({
      event,
      // Lets the UI drop late updates from the previous item.
      itemId: this.itemId,
      playing: ok && !v!.paused && !this.buffering,
      buffering: this.buffering,
      position: ok ? Math.max(0, v!.currentTime || 0) : 0,
      duration: dur,
      videoWidth: this.videoW,
      videoHeight: this.videoH,
      speed: this.speed,
      aspectMode: this.aspect,
      audioTracks: this.audioTracks,
      subtitleTracks: this.subtitleTracks,
      selectedAudioTrack: this.selectedAudio,
      selectedSubtitleTrack: this.selectedSubtitle,
      ...(error ? {error} : {}),
    });
  }
}
