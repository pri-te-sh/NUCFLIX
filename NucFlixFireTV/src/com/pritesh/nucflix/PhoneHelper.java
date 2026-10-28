package com.pritesh.nucflix;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/**
 * Companion HTTP server running on the Fire TV (port 8765): open http://<firetv-ip>:8765 on a phone or
 * computer on the same network to search the catalog or type into the focused TV text field.
 */
final class PhoneHelper {

    interface Actions {
        void search(String query);
        void typeText(String text);
    }

    private final int port;
    private final Actions actions;
    private ServerSocket server;

    PhoneHelper(int port, Actions actions) {
        this.port = port;
        this.actions = actions;
    }

    synchronized void start() {
        if (server != null) return;
        try {
            server = new ServerSocket();
        } catch (IOException e) {
            return;
        }
        final ServerSocket s = server;
        new Thread(() -> serve(s), "NucFlix-PhoneHelper").start();
    }

    synchronized void stop() {
        if (server == null) return;
        try {
            server.close();
        } catch (IOException ignored) {
        }
        server = null;
    }

    private void serve(ServerSocket s) {
        try {
            s.setReuseAddress(true);
            s.bind(new InetSocketAddress(port));
            while (!s.isClosed()) {
                try (Socket client = s.accept()) {
                    client.setSoTimeout(5000);
                    handle(client);
                } catch (IOException ignored) {
                }
            }
        } catch (IOException ignored) {
        }
    }

    private void handle(Socket client) throws IOException {
        BufferedReader in = new BufferedReader(new InputStreamReader(client.getInputStream(), StandardCharsets.UTF_8));
        String requestLine = in.readLine();
        if (requestLine == null) return;
        String[] parts = requestLine.split(" ");
        if (parts.length < 2) return;
        String method = parts[0];
        String path = parts[1];

        int length = 0;
        for (String line = in.readLine(); line != null && !line.isEmpty(); line = in.readLine()) {
            int colon = line.indexOf(':');
            if (colon > 0 && line.substring(0, colon).trim().equalsIgnoreCase("Content-Length")) {
                try {
                    length = Integer.parseInt(line.substring(colon + 1).trim());
                } catch (NumberFormatException e) {
                    length = -1;
                }
            }
        }
        OutputStream out = client.getOutputStream();

        if (method.equals("GET") && (path.equals("/") || path.startsWith("/?"))) {
            send(out, 200, "text/html; charset=utf-8", PAGE);
            return;
        }
        if (!method.equals("POST")) {
            send(out, 404, "application/json", "{\"ok\":false,\"error\":\"Not found\"}");
            return;
        }
        if (length < 0 || length > 8192) {
            send(out, 413, "application/json", "{\"ok\":false,\"error\":\"Payload too large\"}");
            return;
        }
        char[] body = new char[length];
        int read = 0;
        while (read < length) {
            int n = in.read(body, read, length - read);
            if (n < 0) break;
            read += n;
        }
        Map<String, String> form = parseForm(new String(body, 0, read));

        switch (path) {
            case "/search":
                actions.search(form.getOrDefault("query", ""));
                send(out, 200, "application/json", "{\"ok\":true}");
                break;
            case "/type":
                actions.typeText(form.getOrDefault("text", ""));
                send(out, 200, "application/json", "{\"ok\":true}");
                break;
            default:
                send(out, 404, "application/json", "{\"ok\":false,\"error\":\"Unknown route\"}");
                break;
        }
    }

    private static Map<String, String> parseForm(String body) {
        Map<String, String> form = new HashMap<>();
        for (String pair : body.split("&")) {
            int eq = pair.indexOf('=');
            if (eq <= 0) continue;
            try {
                form.put(URLDecoder.decode(pair.substring(0, eq), "UTF-8"),
                        URLDecoder.decode(pair.substring(eq + 1), "UTF-8"));
            } catch (Exception ignored) {
            }
        }
        return form;
    }

    private static void send(OutputStream out, int status, String type, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        String head = "HTTP/1.1 " + status + " OK\r\n"
                + "Content-Type: " + type + "\r\n"
                + "Content-Length: " + bytes.length + "\r\n"
                + "Access-Control-Allow-Origin: *\r\n"
                + "Cache-Control: no-store\r\n"
                + "Connection: close\r\n\r\n";
        out.write(head.getBytes(StandardCharsets.UTF_8));
        out.write(bytes);
        out.flush();
    }

    private static final String PAGE = "<!doctype html><html lang='en'><head><meta charset='utf-8'>"
            + "<meta name='viewport' content='width=device-width,initial-scale=1'>"
            + "<title>NucFlix TV Companion</title><style>"
            + ":root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#000;color:#fff;font:15px/1.45 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif}"
            + "main{max-width:460px;margin:0 auto;padding:24px 16px 48px}"
            + ".brand{display:flex;align-items:center;gap:12px;margin-bottom:20px}"
            + ".n-badge{width:24px;height:40px;background:linear-gradient(135deg,#b20710 0%,#e50914 50%,#b20710 100%);border-radius:4px;display:flex;align-items:center;justify-content:center;font-weight:900;font-size:24px;color:#fff;box-shadow:0 4px 16px rgba(229,9,20,.5)}"
            + "h1{font-size:24px;font-weight:800;margin:0}p.sub{color:#a3a3a3;font-size:13px;margin:4px 0 0}"
            + "section{background:#141414;border:1px solid rgba(255,255,255,.12);border-radius:16px;padding:18px;margin-bottom:16px}"
            + "h2{font-size:13px;text-transform:uppercase;letter-spacing:1.2px;color:#e50914;margin:0 0 12px;font-weight:800}"
            + "input{width:100%;padding:12px 14px;border-radius:10px;border:1px solid rgba(255,255,255,.16);background:#090909;color:#fff;font-size:16px;margin-bottom:12px}"
            + "input:focus{outline:none;border-color:#e50914}"
            + ".row{display:flex;gap:10px}button{flex:1;padding:13px 16px;border:0;border-radius:10px;background:#e50914;color:#fff;font-weight:700;font-size:15px;cursor:pointer}"
            + "button.secondary{background:#2b2b2b;color:#fff}"
            + "#msg{min-height:22px;font-size:14px;font-weight:600;text-align:center;margin-top:8px}.ok{color:#46d369}.err{color:#ff5252}"
            + "</style></head><body><main>"
            + "<div class='brand'><div class='n-badge'>N</div><div><h1>NucFlix for Fire TV</h1><p class='sub'>Search or type on the TV from your phone</p></div></div>"
            + "<section><h2>Search on TV</h2>"
            + "<input id='q' placeholder='Search channels, movies, series...'>"
            + "<div class='row'><button onclick='sendSearch()'>Search on TV</button><button class='secondary' onclick='sendType()'>Type into TV Field</button></div></section>"
            + "<div id='msg'></div></main><script>"
            + "function post(path,params,doneMsg){var body=Object.keys(params).map(function(k){return encodeURIComponent(k)+'='+encodeURIComponent(params[k]||'')}).join('&');"
            + "fetch(path,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body}).then(function(r){return r.json()}).then(function(j){var m=document.getElementById('msg');m.className=j.ok?'ok':'err';m.textContent=j.ok?doneMsg:(j.error||'Failed');});}"
            + "function sendSearch(){post('/search',{query:document.getElementById('q').value},'Opened search on Fire TV!');}"
            + "function sendType(){post('/type',{text:document.getElementById('q').value},'Typed into TV field!');}"
            + "</script></body></html>";
}
