package com.nostrvault.relay

import java.net.HttpURLConnection
import java.net.URL
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Whether what answers on the relay port is this app's relay. A bare TCP
 * connect also succeeds against another app holding the port (Citrine, or
 * any relay app set to the same port), and the notification then said
 * "Relay running" while ours had failed to bind. The embedded relay's NIP-11
 * names its software (haven-go config.go relaySoftware).
 */
object RelayIdentity {
    const val SOFTWARE = "https://github.com/barrydeen/haven"

    /** Blocking: asks 127.0.0.1:[port] for its NIP-11. Throws if nothing answers. */
    fun answersAsOurs(port: Int, timeoutMs: Int): Boolean {
        val conn = URL("http://127.0.0.1:$port/").openConnection() as HttpURLConnection
        return try {
            conn.connectTimeout = timeoutMs
            conn.readTimeout = timeoutMs
            conn.setRequestProperty("Accept", "application/nostr+json")
            isOurs(conn.inputStream.bufferedReader().use { it.readText() })
        } finally {
            conn.disconnect()
        }
    }

    fun isOurs(nip11Json: String): Boolean = runCatching {
        Json.parseToJsonElement(nip11Json).jsonObject["software"]?.jsonPrimitive?.contentOrNull == SOFTWARE
    }.getOrDefault(false)
}
