package com.nostrvault.util

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import java.net.URI

/**
 * What someone pasted (or scanned) into the wallet's Send box.
 *
 * One box takes every shape people actually hand each other — a bolt11
 * invoice, a Lightning address, a bech32 LNURL, an LUD-17 `lnurlp://` /
 * `lnurlw://` link, and any of those behind a `lightning:` prefix or inside a
 * BIP21 `bitcoin:` link — so the user never has to know which one they have.
 *
 * Plain Kotlin, no Android types, so it runs under JVM unit tests.
 * Port of iOS LightningPayTarget.swift.
 */
sealed interface LightningPayTarget {
    /** A bolt11 invoice, lowercased. */
    data class Invoice(val bolt11: String) : LightningPayTarget

    /** A Lightning address (LUD-16), `name@domain`, lowercased. */
    data class Address(val address: String) : LightningPayTarget

    /** A bech32 LNURL (LUD-01), lowercased, still encoded. */
    data class Lnurl(val bech32: String) : LightningPayTarget

    /** An LUD-17 link already turned into the http(s) URL it stands for. */
    data class LnurlUrl(val url: String) : LightningPayTarget

    companion object {
        fun parse(raw: String): LightningPayTarget? {
            var text = raw.trim()
            if (text.isEmpty()) return null

            // BIP21: `bitcoin:addr?amount=…&lightning=lnbc…` — the lightning
            // parameter is the part this wallet can pay.
            if (text.lowercase().startsWith("bitcoin:")) {
                val query = text.split("?", limit = 2).getOrNull(1) ?: return null
                val lightning = query.split("&")
                    .firstOrNull { it.lowercase().startsWith("lightning=") }
                    ?: return null
                text = percentDecode(lightning.substring("lightning=".length))
            }

            if (text.lowercase().startsWith("lightning:")) {
                // Some wallets write `lightning://`.
                text = text.substring("lightning:".length).trimStart('/')
            }
            text = text.trim()
            val lower = text.lowercase()

            for (scheme in listOf("lnurlp://", "lnurlw://")) {
                if (!lower.startsWith(scheme)) continue
                val rest = text.substring(scheme.length)
                // LUD-17: onion hosts stay on http, everything else is https.
                val host = rest.split("/", limit = 2).first().lowercase()
                val httpScheme = if (host.endsWith(".onion")) "http://" else "https://"
                val url = httpScheme + rest
                val parsed = runCatching { URI(url) }.getOrNull() ?: return null
                if (parsed.host.isNullOrEmpty()) return null
                return LnurlUrl(url)
            }

            if (lower.startsWith("lnurl1")) return Lnurl(lower)

            // Before the invoice test: `lntbob@getalby.com` is an address.
            if (isLightningAddress(lower)) return Address(lower)

            // lnbc (mainnet), lntb (testnet), lntbs (signet), lnbcrt (regtest).
            if ((lower.startsWith("lnbc") || lower.startsWith("lntb")) && '@' !in lower) {
                return Invoice(lower)
            }
            return null
        }

        private const val NAME_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789-_.+"
        private const val DOMAIN_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789-.:"

        /** `name@domain.tld` with nothing the well-known URL could not carry. */
        fun isLightningAddress(s: String): Boolean {
            val parts = s.split("@")
            if (parts.size != 2) return false
            val (name, domain) = parts
            if (name.isEmpty() || !domain.contains('.') || domain.startsWith('.') || domain.endsWith('.')) {
                return false
            }
            return name.all { it in NAME_CHARS } && domain.all { it in DOMAIN_CHARS }
        }

        /** `%XX` decoding only — unlike URLDecoder, `+` stays a `+`. */
        private fun percentDecode(s: String): String {
            if (!s.contains('%')) return s
            val out = java.io.ByteArrayOutputStream()
            var i = 0
            while (i < s.length) {
                val c = s[i]
                if (c == '%' && i + 3 <= s.length) {
                    val hex = s.substring(i + 1, i + 3).toIntOrNull(16)
                    if (hex != null) {
                        out.write(hex)
                        i += 3
                        continue
                    }
                }
                out.write(c.toString().toByteArray(Charsets.UTF_8))
                i++
            }
            return out.toString(Charsets.UTF_8.name())
        }
    }
}

/**
 * The range an LNURL service will accept, and whether an amount fits it.
 * LNURL speaks millisatoshis; people type sats.
 */
data class LNURLAmountRange(val minMsat: Long, val maxMsat: Long) {
    /** Smallest whole sat the service accepts (rounded up). */
    val minSats: Long get() = (minMsat + 999) / 1000

    /** Largest whole sat the service accepts (rounded down). */
    val maxSats: Long get() = maxMsat / 1000

    /** Services that take exactly one amount (a fixed-price LNURL). */
    val isFixed: Boolean get() = minSats == maxSats

    sealed interface Check {
        data class Ok(val msat: Long) : Check
        data class TooSmall(val minSats: Long) : Check
        data class TooLarge(val maxSats: Long) : Check
        data object Invalid : Check
    }

    fun check(sats: Long?): Check {
        if (sats == null || sats <= 0) return Check.Invalid
        // Compared in sats first: `sats * 1000` wraps silently for a long
        // enough number typed into the field, and a wrapped negative would
        // read as "too small" — or, worse, land inside the range.
        if (sats > maxSats) return Check.TooLarge(maxSats)
        val msat = sats * 1000
        if (msat < minMsat) return Check.TooSmall(minSats)
        return Check.Ok(msat)
    }
}

/**
 * The `text/plain` line of LNURL-pay metadata — the service's own description
 * of what you are paying for. Metadata is a JSON array of `[mime, value]`
 * pairs, delivered as a string.
 */
fun lnurlPlainTextMetadata(metadata: String): String? {
    val entries = runCatching { Json.parseToJsonElement(metadata) as? JsonArray }.getOrNull() ?: return null
    for (entry in entries) {
        val pair = entry as? JsonArray ?: continue
        if (pair.size < 2) continue
        if (pair[0].stringOrNull() != "text/plain") continue
        val text = pair[1].stringOrNull()
        if (!text.isNullOrEmpty()) return text
    }
    return null
}

/** One payment from the wallet's history (NIP-47 `list_transactions`). */
data class WalletTransaction(
    val id: String,
    val direction: Direction,
    val state: State,
    val amountSats: Long,
    val feeSats: Long,
    val description: String?,
    /** Unix seconds. */
    val createdAt: Long,
    /** Unix seconds. */
    val settledAt: Long?,
) {
    enum class Direction { INCOMING, OUTGOING }
    enum class State { SETTLED, PENDING, FAILED, EXPIRED }

    companion object {
        /**
         * Builds one from the decrypted NIP-47 transaction object. Wallets are
         * loose about number types (int, double, numeric string), so every
         * number is read through [number]. Returns null only when the entry is
         * unusable — no direction or no time.
         */
        fun fromNip47(obj: JsonObject): WalletTransaction? {
            val type = obj["type"].stringOrNull() ?: return null
            val direction = when (type.lowercase()) {
                "incoming" -> Direction.INCOMING
                "outgoing" -> Direction.OUTGOING
                else -> return null
            }
            val created = number(obj["created_at"]) ?: return null
            val settledAt = number(obj["settled_at"])
            val amountSats = (number(obj["amount"]) ?: 0L) / 1000
            val feeSats = (number(obj["fees_paid"]) ?: 0L) / 1000
            val description = obj["description"].stringOrNull()?.trim()?.ifEmpty { null }

            // `state` is newer in NIP-47; older wallets only send `settled_at`.
            val state = when (obj["state"].stringOrNull()?.lowercase()) {
                "settled" -> State.SETTLED
                "pending" -> State.PENDING
                "failed" -> State.FAILED
                "expired" -> State.EXPIRED
                else -> if (settledAt != null) State.SETTLED else State.PENDING
            }

            val id = obj["payment_hash"].stringOrNull()
                ?: obj["invoice"].stringOrNull()
                ?: "$type-$created-$amountSats"

            return WalletTransaction(
                id = id,
                direction = direction,
                state = state,
                amountSats = amountSats,
                feeSats = feeSats,
                description = description,
                createdAt = created,
                settledAt = settledAt,
            )
        }

        private fun number(element: JsonElement?): Long? {
            val p = element as? JsonPrimitive ?: return null
            if (p.isString) return p.content.toLongOrNull() ?: p.content.toDoubleOrNull()?.let(::wholeOrNull)
            return p.longOrNull ?: p.doubleOrNull?.let(::wholeOrNull)
        }

        /**
         * A double that fits a Long, truncated; null otherwise. Kotlin's
         * toLong() would turn NaN into 0 and 1e300 into Long.MAX_VALUE —
         * garbage that reads as a real number.
         */
        private fun wholeOrNull(d: Double): Long? {
            if (d.isNaN() || d < Long.MIN_VALUE.toDouble() || d >= Long.MAX_VALUE.toDouble()) return null
            return d.toLong()
        }

        /**
         * Wallets return history newest first in theory, not always in
         * practice; pages are merged and re-sorted, and a payment that shows up
         * on two pages (the list moved between requests) appears once.
         */
        fun merge(existing: List<WalletTransaction>, page: List<WalletTransaction>): List<WalletTransaction> =
            (existing + page)
                .distinctBy { it.id }
                .sortedByDescending { it.createdAt }
    }
}

private fun JsonElement?.stringOrNull(): String? =
    (this as? JsonPrimitive)?.takeIf { it.isString }?.content
