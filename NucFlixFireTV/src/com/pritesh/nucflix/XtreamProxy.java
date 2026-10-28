package com.pritesh.nucflix;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.util.LruCache;
import android.webkit.WebResourceResponse;

import org.json.JSONObject;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.zip.GZIPInputStream;

/**
 * Proxies Xtream Codes API calls (/api/xtream?url=...) and remote artwork (/api/img?url=...)
 * directly from Java so http:// IPTV panels work seamlessly inside the https://app.local WebView
 * with zero mixed-content or CORS errors.
 */
final class XtreamProxy {
    static final String USER_AGENT = "IPTVSmartersPlayer/3.0 (iOS; iPhone; Scale/3.00)";

    private static final LruCache<String, byte[]> IMAGE_CACHE = new LruCache<String, byte[]>(24 * 1024 * 1024) {
        @Override
        protected int sizeOf(String key, byte[] value) {
            return value.length;
        }
    };

    private XtreamProxy() {}

    static WebResourceResponse fetchJson(String targetUrl) {
        if (targetUrl == null || (!targetUrl.startsWith("http://") && !targetUrl.startsWith("https://"))) {
            return errorJson(400, "This IPTV line has an invalid server URL. Fix it in the NucFlix iPhone app (Settings → IPTV Lines).");
        }
        HttpURLConnection conn = null;
        try {
            conn = openWithRedirects(targetUrl, 25000, 45000, "application/json, */*");
            int code = conn.getResponseCode();
            if (code < 200 || code >= 300) {
                if (code == 401 || code == 403) {
                    return errorJson(code, "Server rejected the credentials (HTTP " + code + "). The line may be expired, disabled, or blocked.");
                } else if (code == 884) {
                    return errorJson(code, "All connection slots are in use (HTTP 884). Close other devices using this line and try again.");
                }
                return errorJson(code, "Server returned HTTP status " + code + ". Check the line's server URL and port in the NucFlix iPhone app.");
            }
            byte[] body = readStream(conn);
            return new WebResourceResponse("application/json", "utf-8", 200, "OK", corsHeaders(), new ByteArrayInputStream(body));
        } catch (Exception e) {
            String msg = e.getMessage() != null ? e.getMessage() : e.getClass().getSimpleName();
            return errorJson(502, "Network error connecting to server: " + msg);
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    /**
     * Fetches artwork and, when {@code maxWidth} > 0, downsizes it to that width (JPEG q82) before caching.
     * Providers serve 600x900+ posters; decoding hundreds of those in the WebView was a major source of
     * memory pressure and dropped frames on the Fire TV.
     */
    static WebResourceResponse fetchImage(String targetUrl, int maxWidth) {
        if (targetUrl == null || (!targetUrl.startsWith("http://") && !targetUrl.startsWith("https://"))) {
            return emptyImage();
        }
        String key = maxWidth + "|" + targetUrl;
        byte[] cached = IMAGE_CACHE.get(key);
        if (cached != null) {
            return new WebResourceResponse(maxWidth > 0 ? "image/jpeg" : guessImageMime(targetUrl), null, 200, "OK",
                    corsHeaders(), new ByteArrayInputStream(cached));
        }
        HttpURLConnection conn = null;
        try {
            conn = openWithRedirects(targetUrl, 8000, 12000, "image/*,*/*;q=0.8");
            int code = conn.getResponseCode();
            if (code >= 200 && code < 300) {
                byte[] bytes = readStream(conn);
                String ct = conn.getContentType();
                String mime = (ct != null && ct.startsWith("image/")) ? ct.split(";")[0].trim() : guessImageMime(targetUrl);
                if (maxWidth > 0) {
                    byte[] scaled = downscale(bytes, maxWidth);
                    if (scaled != null) {
                        bytes = scaled;
                        mime = "image/jpeg";
                    }
                }
                if (bytes.length > 0 && bytes.length < 4 * 1024 * 1024) {
                    IMAGE_CACHE.put(key, bytes);
                }
                return new WebResourceResponse(mime, null, 200, "OK", corsHeaders(), new ByteArrayInputStream(bytes));
            }
        } catch (Exception ignored) {
        } finally {
            if (conn != null) conn.disconnect();
        }
        return emptyImage();
    }

    private static byte[] downscale(byte[] src, int maxWidth) {
        try {
            BitmapFactory.Options bounds = new BitmapFactory.Options();
            bounds.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(src, 0, src.length, bounds);
            if (bounds.outWidth <= 0 || bounds.outWidth <= maxWidth * 1.15) return null; // already small
            BitmapFactory.Options opts = new BitmapFactory.Options();
            int sample = 1;
            while (bounds.outWidth / (sample * 2) >= maxWidth) sample *= 2;
            opts.inSampleSize = sample;
            Bitmap decoded = BitmapFactory.decodeByteArray(src, 0, src.length, opts);
            if (decoded == null) return null;
            Bitmap out = decoded;
            if (decoded.getWidth() > maxWidth) {
                int h = Math.max(1, Math.round(decoded.getHeight() * (maxWidth / (float) decoded.getWidth())));
                out = Bitmap.createScaledBitmap(decoded, maxWidth, h, true);
                decoded.recycle();
            }
            java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
            out.compress(Bitmap.CompressFormat.JPEG, 82, bos);
            out.recycle();
            return bos.toByteArray();
        } catch (Throwable t) {
            return null;
        }
    }

    private static HttpURLConnection openWithRedirects(String urlStr, int connectTimeout, int readTimeout, String accept) throws IOException {
        String current = urlStr;
        for (int hops = 0; hops < 5; hops++) {
            HttpURLConnection conn = (HttpURLConnection) new URL(current).openConnection();
            conn.setInstanceFollowRedirects(false);
            conn.setConnectTimeout(connectTimeout);
            conn.setReadTimeout(readTimeout);
            conn.setRequestProperty("User-Agent", USER_AGENT);
            conn.setRequestProperty("Accept", accept);
            conn.setRequestProperty("Accept-Encoding", "gzip");
            int status = conn.getResponseCode();
            if (status == HttpURLConnection.HTTP_MOVED_PERM
                    || status == HttpURLConnection.HTTP_MOVED_TEMP
                    || status == HttpURLConnection.HTTP_SEE_OTHER
                    || status == 307 || status == 308) {
                String loc = conn.getHeaderField("Location");
                conn.disconnect();
                if (loc == null || loc.isEmpty()) break;
                current = new URL(new URL(current), loc).toString();
                continue;
            }
            return conn;
        }
        throw new IOException("Too many redirects");
    }

    private static byte[] readStream(HttpURLConnection conn) throws IOException {
        InputStream raw = conn.getErrorStream() != null && conn.getResponseCode() >= 400
                ? conn.getErrorStream()
                : conn.getInputStream();
        if (raw == null) return new byte[0];
        String encoding = conn.getContentEncoding();
        InputStream in = (encoding != null && encoding.toLowerCase().contains("gzip"))
                ? new GZIPInputStream(raw)
                : raw;
        ByteArrayOutputStream out = new ByteArrayOutputStream(16384);
        byte[] buf = new byte[16384];
        int n;
        while ((n = in.read(buf)) >= 0) {
            out.write(buf, 0, n);
        }
        in.close();
        return out.toByteArray();
    }

    private static String guessImageMime(String url) {
        String lower = url.toLowerCase();
        if (lower.contains(".png")) return "image/png";
        if (lower.contains(".webp")) return "image/webp";
        return "image/jpeg";
    }

    private static WebResourceResponse emptyImage() {
        return new WebResourceResponse("image/png", null, 404, "Not Found", corsHeaders(), new ByteArrayInputStream(new byte[0]));
    }

    static WebResourceResponse errorJson(int status, String message) {
        try {
            JSONObject err = new JSONObject();
            err.put("ok", false);
            err.put("status", status);
            err.put("error", message);
            byte[] bytes = err.toString().getBytes(StandardCharsets.UTF_8);
            return new WebResourceResponse("application/json", "utf-8", 200, "OK", corsHeaders(), new ByteArrayInputStream(bytes));
        } catch (Exception e) {
            return new WebResourceResponse("application/json", "utf-8",
                    new ByteArrayInputStream("{\"ok\":false,\"error\":\"Error\"}".getBytes(StandardCharsets.UTF_8)));
        }
    }

    static Map<String, String> corsHeaders() {
        Map<String, String> h = new HashMap<>();
        h.put("Access-Control-Allow-Origin", "*");
        h.put("Cache-Control", "no-store");
        return h;
    }
}
