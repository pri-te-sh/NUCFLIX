package com.pritesh.nucflix.phone.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/** The parts of the Xtream Codes player API the app needs (checking a login for now). */
object Xtream {

    /** "panel.example.com:8080/player_api.php" -> "https://panel.example.com:8080" (same rules as the iPhone app). */
    fun normalizedBaseUrl(raw: String): String {
        var url = raw.trim()
        if (!url.lowercase().startsWith("http://") && !url.lowercase().startsWith("https://")) url = "https://$url"
        for (tail in listOf("/player_api.php", "/get.php")) {
            val at = url.indexOf(tail, ignoreCase = true)
            if (at >= 0) url = url.substring(0, at)
        }
        return url.trimEnd('/')
    }

    /**
     * Checks the login with the provider and returns the base URL that works. A bare host is tried over https
     * first (the login travels in the URL); panels without TLS fail the handshake and are retried over http.
     */
    suspend fun verify(serverUrl: String, username: String, password: String): String = withContext(Dispatchers.IO) {
        val base = normalizedBaseUrl(serverUrl)
        try {
            try {
                authenticate(base, username, password)
                base
            } catch (e: IOException) {
                if (!base.startsWith("https://", ignoreCase = true)) throw e
                val plain = "http://" + base.substring("https://".length)
                authenticate(plain, username, password)
                plain
            }
        } catch (e: IOException) {
            throw CloudError("Couldn't reach that server. Check the address and your connection.")
        }
    }

    private fun authenticate(base: String, username: String, password: String) {
        val enc = { s: String -> URLEncoder.encode(s, "UTF-8") }
        val conn = URL("$base/player_api.php?username=${enc(username)}&password=${enc(password)}").openConnection() as HttpURLConnection
        conn.connectTimeout = 15_000
        conn.readTimeout = 20_000
        val body = try {
            conn.inputStream.bufferedReader().use { it.readText() }
        } finally {
            conn.disconnect()
        }
        val info = try {
            JSONObject(body).optJSONObject("user_info")
        } catch (e: JSONException) {
            throw CloudError("That server didn't answer like an IPTV panel. Check the server address.")
        } ?: throw CloudError("Authentication failed: the server did not return account information.")
        val status = info.optString("status").lowercase()
        // A dead line comes back as status "Expired"/"Disabled" with auth = 0: say so instead of "wrong password".
        if (status == "expired" || status == "disabled") {
            throw CloudError("This subscription is $status. Renew or extend the line with your IPTV provider to restore access.")
        }
        val auth = info.opt("auth")?.toString()
        if (auth != "1" && auth != "true") {
            val reason = info.optString("status").ifEmpty { info.optString("message") }.ifEmpty { "Invalid username or password." }
            throw CloudError("Authentication failed: $reason")
        }
    }
}
