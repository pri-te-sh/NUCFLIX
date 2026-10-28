package com.pritesh.nucflix;

import android.net.Uri;
import android.util.Log;

import androidx.media3.common.C;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.TransferListener;

import java.io.IOException;
import java.util.List;
import java.util.Map;

/** Live MPEG-TS source that runs the feed through {@link TsTimestampRebaser} (fresh state per connection). */
final class TsRebaseDataSource implements DataSource {
    private final DataSource upstream;
    private final byte[] chunk = new byte[64 * 1024];
    private TsTimestampRebaser rebaser;
    private byte[] out = new byte[0];
    private int outPos;
    private boolean ended;

    TsRebaseDataSource(DataSource upstream) {
        this.upstream = upstream;
    }

    @Override
    public void addTransferListener(TransferListener transferListener) {
        upstream.addTransferListener(transferListener);
    }

    @Override
    public long open(DataSpec dataSpec) throws IOException {
        rebaser = new TsTimestampRebaser((pid, off) ->
                Log.i("NucFlix", "Re-basing TS audio PID " + pid + " by " + (off / 90_000.0) + " s"));
        out = new byte[0];
        outPos = 0;
        ended = false;
        return upstream.open(dataSpec);
    }

    @Override
    public int read(byte[] buffer, int offset, int length) throws IOException {
        if (length == 0) return 0;
        while (outPos >= out.length) {
            if (ended) return C.RESULT_END_OF_INPUT;
            int n = upstream.read(chunk, 0, chunk.length);
            if (n == C.RESULT_END_OF_INPUT) {
                ended = true;
                rebaser.push(chunk, 0, 0, true);
            } else {
                rebaser.push(chunk, 0, n, false);
            }
            out = rebaser.take();
            outPos = 0;
        }
        int n = Math.min(length, out.length - outPos);
        System.arraycopy(out, outPos, buffer, offset, n);
        outPos += n;
        return n;
    }

    @Override
    public Uri getUri() {
        return upstream.getUri();
    }

    @Override
    public Map<String, List<String>> getResponseHeaders() {
        return upstream.getResponseHeaders();
    }

    @Override
    public void close() throws IOException {
        out = new byte[0];
        outPos = 0;
        upstream.close();
    }
}
