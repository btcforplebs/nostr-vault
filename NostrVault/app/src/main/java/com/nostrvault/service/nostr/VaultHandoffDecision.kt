package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

/**
 * Publish for me (sync pick 1, Logen 2026-11-12): who blasts a note the phone handed its vault. Exactly one device
 * does: the vault only when the connection's first frame was `["NOTICE", "publish-for-me: on"]` ([PUBLISH_NOTICE]) and
 * it then answered `["OK", id, true, ""]` within the hold, which it does only after storing the note and queueing its
 * blast (haven-go mesh_publish.go). Anything else (no notice first: an older or unpairing vault; an OK false such as
 * "duplicate:", "blocked:" or "restricted:"; a refused upgrade; a closed socket; no answer in time) means the vault
 * will not send it, so the phone does. Pure for the tests. Twin of Apple's `VaultHandoffDecision`.
 */
enum class VaultHandoffDecision {
    /** The vault stored the note and queued its blast: the phone keeps a second-hand copy and does not blast. */
    VAULT_SENDS,

    /** The vault will not send it: the phone posts exactly as without a vault. */
    PHONE_SENDS;

    companion object {
        /** A publish connection's first frame from a vault that sends for this device (Go meshPublishNotice). */
        const val PUBLISH_NOTICE = "publish-for-me: on"

        /**
         * [connected]: the socket opened. [sawPublishNotice]: its first frame was [PUBLISH_NOTICE] (an older vault
         * answers a plain OK true and never sends). [accepted] / [message]: the vault's OK for this note, null without
         * one. [timedOut]: the hold ran out first (a late OK true then changes nothing: the phone already sent it).
         */
        fun decide(connected: Boolean, sawPublishNotice: Boolean, accepted: Boolean?, message: String?, timedOut: Boolean): VaultHandoffDecision =
            if (connected && sawPublishNotice && !timedOut && accepted == true && message.isNullOrBlank()) VAULT_SENDS else PHONE_SENDS

        /**
         * Whether a note of [kind] is handed to the vault at all: regular kinds only. A profile (0), a follow list
         * (3), replaceable (10000-19999), ephemeral (20000-29999) and addressable (30000-39999) kinds go the phone's
         * way, with no hold (Tron review of PR 1970, M1). Twin of Apple's `handsOff(kind:)`.
         */
        fun handsOff(kind: Int): Boolean = kind > 0 && kind != 3 && kind !in 10_000..39_999

        /** Whether [text] is exactly `["NOTICE", "publish-for-me: on"]`. */
        fun isPublishNotice(text: String): Boolean = runCatching {
            val parsed = Json.parseToJsonElement(text).jsonArray
            parsed.size == 2 && parsed[0].jsonPrimitive.contentOrNull == "NOTICE" && parsed[1].jsonPrimitive.contentOrNull == PUBLISH_NOTICE
        }.getOrDefault(false)

        /** The accepted flag and message of an `OK` for [eventId], or null for any other message. */
        fun okAnswer(text: String, eventId: String): Pair<Boolean, String>? = runCatching {
            val parsed = Json.parseToJsonElement(text).jsonArray
            if (parsed.size < 3 || parsed[0].jsonPrimitive.contentOrNull != "OK") return null
            if (parsed[1].jsonPrimitive.contentOrNull != eventId) return null
            (parsed[2].jsonPrimitive.booleanOrNull ?: false) to (parsed.getOrNull(3)?.jsonPrimitive?.contentOrNull ?: "")
        }.getOrNull()
    }
}
