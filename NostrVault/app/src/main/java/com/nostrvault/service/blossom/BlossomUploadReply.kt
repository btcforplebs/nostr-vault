package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.net.URI

/**
 * What an outside Blossom server's answer to `PUT /upload` means. Port of iOS
 * `BlossomUploadReply`.
 *
 * BUD-02 says a server that stores the blob answers with a blob descriptor:
 * JSON carrying the blob's `url` and `sha256`. A 2xx without one is not an
 * upload. nostr.build's own website (`https://nostr.build`, and every
 * `<name>.nostr.build` subdomain) answers any `PUT /upload` with `200` and its
 * HTML home page, and serves that same page for `/<sha256>`. Taking the 200
 * as success put a link to a web page in the note, so the picture never
 * showed (2026-10-16). Its Blossom server is `https://blossom.nostr.build`.
 */
object BlossomUploadReply {
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * The link to put in the note, or null when the reply isn't a stored blob.
     * [onDeviceRelay]: this device's own relay, which is ours and is addressed
     * by hash, so `<server>/<sha256>` is right whatever it says.
     */
    fun hostedUrl(body: String?, server: String, sha256: String, onDeviceRelay: Boolean): String? {
        if (onDeviceRelay) return "${server.trimEnd('/')}/$sha256"
        val obj = try {
            json.parseToJsonElement(body ?: return null) as? JsonObject
        } catch (e: Exception) {
            null
        } ?: return null
        val url = (obj["url"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
        val uri = try { URI(url) } catch (e: Exception) { return null }
        val scheme = uri.scheme?.lowercase()
        if ((scheme != "https" && scheme != "http") || uri.host.isNullOrEmpty()) return null
        // A descriptor for some other blob is not this upload.
        val hash = (obj["sha256"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        if (hash != null && !hash.equals(sha256, ignoreCase = true)) return null
        return url
    }

    /** For the log: what came back instead of a descriptor. */
    fun describe(body: String?, contentType: String?): String =
        "${contentType ?: "no content type"}: ${body?.take(80)?.replace('\n', ' ')?.trim() ?: "(empty)"}"

    private val onDeviceHosts = setOf("localhost", "127.0.0.1", "0.0.0.0")

    /** Strictly this device (not the LAN): the only server addressed by hash. */
    fun isOnDevice(server: String): Boolean =
        try { URI(server).host?.lowercase() in onDeviceHosts } catch (e: Exception) { false }
}
