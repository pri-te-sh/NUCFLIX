package com.pritesh.nucflix;

import java.io.ByteArrayOutputStream;
import java.util.HashMap;
import java.util.Map;

/**
 * Repairs MPEG-TS feeds whose audio timestamps are wildly offset from the video (seen on some provider
 * channels: audio PTS ~26 hours ahead of video, in both the .ts and HLS outputs). No player can line those
 * up, so playback never starts. Each audio PID's PTS/DTS is shifted by its offset from the video clock,
 * measured at the PID's first PES packet; offsets under {@link #THRESHOLD} are left alone, so healthy feeds
 * pass through byte-for-byte.
 *
 * Usage: {@link #push} raw bytes, then drain them from {@link #take}. The start of the feed is held back
 * (bounded) until the offsets are known, so the first audio packets get fixed as well.
 */
final class TsTimestampRebaser {
    private static final int PKT = 188;
    private static final long PTS_MOD = 1L << 33;
    static final long THRESHOLD = 30L * 90_000; // 30 s in 90 kHz ticks
    private static final int MAX_HOLD = 1536 * 1024;
    private static final int AUDIO_ONLY_PES = 50;

    interface Listener {
        void onRebase(int pid, long offsetTicks);
    }

    private final Listener listener;
    private final Map<Integer, Long> offsets = new HashMap<>();
    private long lastVideoPts = -1;
    private int audioPesSeen = 0;
    private boolean holding = true;
    private final ByteArrayOutputStream ready = new ByteArrayOutputStream(64 * 1024);
    private byte[] pending = new byte[0]; // bytes not yet forming a whole packet

    TsTimestampRebaser(Listener listener) {
        this.listener = listener;
    }

    /** Adds upstream bytes; {@code end} flushes everything (end of stream). */
    void push(byte[] data, int off, int len, boolean end) {
        byte[] buf = new byte[pending.length + len];
        System.arraycopy(pending, 0, buf, 0, pending.length);
        System.arraycopy(data, off, buf, pending.length, len);
        int i = 0;
        int n = buf.length;
        while (n - i >= PKT) {
            if (buf[i] != 0x47) { // lost sync: pass bytes through until the next sync byte
                int j = i + 1;
                while (j < n && buf[j] != 0x47) j++;
                ready.write(buf, i, j - i);
                i = j;
                continue;
            }
            scan(buf, i, !holding);
            ready.write(buf, i, PKT);
            i += PKT;
        }
        if (end) {
            ready.write(buf, i, n - i);
            i = n;
        }
        pending = new byte[n - i];
        System.arraycopy(buf, i, pending, 0, pending.length);
        if (holding && (decided() || ready.size() > MAX_HOLD || end)) release();
    }

    /** Bytes ready for the player (empty while the start of the feed is still being held). */
    byte[] take() {
        if (holding || ready.size() == 0) return new byte[0];
        byte[] b = ready.toByteArray();
        ready.reset();
        return b;
    }

    private boolean decided() {
        return (lastVideoPts >= 0 && !offsets.isEmpty()) || (lastVideoPts < 0 && audioPesSeen >= AUDIO_ONLY_PES);
    }

    /** Stops holding: re-walks the held packets, this time rewriting audio timestamps. */
    private void release() {
        holding = false;
        byte[] held = ready.toByteArray();
        lastVideoPts = -1; // replay the video clock so late-decided PIDs are measured the same way
        for (int i = 0; i + PKT <= held.length; ) {
            if (held[i] != 0x47) { i++; continue; }
            scan(held, i, true);
            i += PKT;
        }
        ready.reset();
        ready.write(held, 0, held.length);
    }

    /** Looks at one packet; tracks the video clock, decides per-PID offsets and (if {@code write}) applies them. */
    private void scan(byte[] b, int i, boolean write) {
        boolean pusi = (b[i + 1] & 0x40) != 0;
        int afc = (b[i + 3] >> 4) & 3;
        if (!pusi || (afc & 1) == 0) return;
        int p = i + 4;
        if (afc == 3) p += 1 + (b[i + 4] & 0xff);
        int end = i + PKT;
        if (p + 14 > end || b[p] != 0 || b[p + 1] != 0 || b[p + 2] != 1) return;
        int sid = b[p + 3] & 0xff;
        boolean video = sid >= 0xE0 && sid <= 0xEF;
        boolean audio = (sid >= 0xC0 && sid <= 0xDF) || sid == 0xBD;
        if (!video && !audio) return;
        int ptsDts = (b[p + 7] & 0xc0) >> 6;
        if ((ptsDts & 2) == 0) return;
        long pts = readTs(b, p + 9);
        if (video) {
            // Muxers interleave by decode time, so the video DTS is the fairer clock to compare audio with.
            lastVideoPts = ptsDts == 3 && p + 19 <= end ? readTs(b, p + 14) : pts;
            return;
        }
        audioPesSeen++;
        int pid = ((b[i + 1] & 0x1f) << 8) | (b[i + 2] & 0xff);
        Long off = offsets.get(pid);
        if (off == null) {
            if (lastVideoPts < 0) return; // decide once the video clock is known
            long d = wrap(pts - lastVideoPts);
            off = Math.abs(d) > THRESHOLD ? d : 0L;
            offsets.put(pid, off);
            if (off != 0 && listener != null) listener.onRebase(pid, off);
        }
        if (!write || off == 0) return;
        writeTs(b, p + 9, mod(pts - off));
        if (ptsDts == 3 && p + 19 <= end) writeTs(b, p + 14, mod(readTs(b, p + 14) - off));
    }

    private static long wrap(long d) {
        d = mod(d);
        return d >= PTS_MOD / 2 ? d - PTS_MOD : d;
    }

    private static long mod(long v) {
        return ((v % PTS_MOD) + PTS_MOD) % PTS_MOD;
    }

    static long readTs(byte[] b, int o) {
        return ((long) (b[o] & 0x0E) << 29)
                | ((long) (b[o + 1] & 0xff) << 22)
                | ((long) ((b[o + 2] & 0xff) >> 1) << 15)
                | ((long) (b[o + 3] & 0xff) << 7)
                | ((b[o + 4] & 0xff) >> 1);
    }

    static void writeTs(byte[] b, int o, long v) {
        b[o] = (byte) ((b[o] & 0xF1) | ((v >> 29) & 0x0E));
        b[o + 1] = (byte) (v >> 22);
        b[o + 2] = (byte) (((v >> 14) & 0xFE) | 1);
        b[o + 3] = (byte) (v >> 7);
        b[o + 4] = (byte) (((v << 1) & 0xFE) | 1);
    }
}
