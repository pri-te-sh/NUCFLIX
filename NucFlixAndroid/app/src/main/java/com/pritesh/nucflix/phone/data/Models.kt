package com.pritesh.nucflix.phone.data

import java.security.MessageDigest
import java.util.Date

/** An Xtream Codes line. Profile-agnostic: any profile in the household plays through it. */
data class CloudLine(
    val id: String,
    val name: String,
    val serverUrl: String,
    val username: String,
    val password: String
) {
    companion object {
        fun from(id: String, data: Map<String, Any?>): CloudLine? {
            val serverUrl = data["serverURL"] as? String ?: return null
            val username = data["username"] as? String ?: return null
            return CloudLine(id, data["name"] as? String ?: "IPTV", serverUrl, username, data["password"] as? String ?: "")
        }
    }
}

/** A person watching (you, kids, ...). Same document shape as the iPhone and Fire TV apps. */
data class CloudProfile(
    val id: String,
    val name: String,
    val avatar: String,
    val kids: Boolean,
    val order: Int,
    // Synced settings (the prefs map).
    val autoplayNext: Boolean,
    val showAdult: Boolean,
    /** Profile Lock: SHA-256 of "nucflix-pin:<profileId>:<pin>", empty when off. */
    val pinHash: String
) {
    /** Standard profiles may have a 4-digit PIN; kids profiles never do. */
    val isLocked: Boolean get() = !kids && pinHash.isNotEmpty()

    fun pinMatches(pin: String) = isLocked && pinHash(id, pin) == pinHash

    companion object {
        val avatarColors = listOf("red", "blue", "green", "yellow", "purple", "orange", "teal", "pink")

        fun pinHash(profileId: String, pin: String): String =
            MessageDigest.getInstance("SHA-256").digest("nucflix-pin:$profileId:$pin".toByteArray())
                .joinToString("") { "%02x".format(it) }

        @Suppress("UNCHECKED_CAST")
        fun from(id: String, data: Map<String, Any?>): CloudProfile? {
            val name = data["name"] as? String ?: return null
            val kids = data["kids"] as? Boolean ?: false
            val prefs = data["prefs"] as? Map<String, Any?> ?: emptyMap()
            return CloudProfile(
                id = id,
                name = name,
                avatar = data["avatar"] as? String ?: "red",
                kids = kids,
                order = (data["order"] as? Number)?.toInt() ?: 0,
                autoplayNext = prefs["autoplayNext"] as? Boolean ?: true,
                showAdult = !kids && (prefs["showAdult"] as? Boolean ?: false),
                pinHash = prefs["pinHash"] as? String ?: ""
            )
        }
    }
}

/** A Fire TV allowed into the household (users/{uid}/members/{tvUid}). */
data class PairedTv(val id: String, val name: String, val pairedAt: Date?)

/** An error whose message is meant for the user as is. */
class CloudError(message: String) : Exception(message)
