package com.nostrvault.relay

import kotlinx.serialization.json.JsonObject
import java.nio.ByteBuffer
import java.security.MessageDigest

/**
 * Signature checks, each event once.
 *
 * The same note reaches the app many times: from every relay that has it,
 * and again each time a subscription replays history (DMs on every
 * reconnect, the WOT tab's engagement on every open). [HavenBridge.verifyEvent]
 * is a JNI call into Go, a JSON parse and a Schnorr check each time.
 *
 * Only passes are remembered, keyed on everything the check reads: id,
 * pubkey, created_at, kind, tags, content and sig. A copy that differs in any
 * of them (a forged one reusing a real id and signature) has another key and
 * is checked in full; a failure is never remembered, so a bad signature is
 * refused every time. Go's relay keeps its own once-per-event cache
 * (haven-go go-nostr); this one covers events Kotlin reads straight from
 * sockets.
 */
object VerifiedEvents {
    private const val MAX = 20_000
    private val FIELDS = listOf("id", "pubkey", "created_at", "kind", "tags", "content", "sig")

    private val passed = object : LinkedHashMap<ByteBuffer, Unit>(1024, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<ByteBuffer, Unit>?) = size > MAX
    }

    /** Whether [event]'s id and signature check out; [check] runs at most once per passing event. */
    fun verify(event: JsonObject, check: (String) -> Boolean = HavenBridge::verifyEvent): Boolean {
        val key = key(event) ?: return false
        if (synchronized(passed) { passed[key] != null }) return true
        if (!check(event.toString())) return false
        synchronized(passed) { passed[key] = Unit }
        return true
    }

    /** [verify] for an event as relay JSON text, parsed once here. */
    fun verify(eventJson: String, check: (String) -> Boolean = HavenBridge::verifyEvent): Boolean {
        val event = runCatching {
            kotlinx.serialization.json.Json.parseToJsonElement(eventJson) as? JsonObject
        }.getOrNull() ?: return false
        return verify(event, check)
    }

    /** SHA-256 over the checked fields, each with its length; null when one is missing. */
    internal fun key(event: JsonObject): ByteBuffer? {
        val digest = MessageDigest.getInstance("SHA-256")
        for (field in FIELDS) {
            val bytes = (event[field] ?: return null).toString().toByteArray(Charsets.UTF_8)
            digest.update(ByteBuffer.allocate(4).putInt(bytes.size).array())
            digest.update(bytes)
        }
        return ByteBuffer.wrap(digest.digest())
    }

    internal fun clearForTest() = synchronized(passed) { passed.clear() }
}
