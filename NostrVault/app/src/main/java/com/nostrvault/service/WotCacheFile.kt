package com.nostrvault.service

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromStream
import java.io.BufferedInputStream
import java.io.InputStream

/**
 * The relay's `wot_cache.json` (haven-go pkg/wot/simple_in_memory.go), read
 * once: `{"pubkeys": {"<hex>": true, ...}, "vouches": {"<hex>": n, ...}, "timestamp": ...}`.
 *
 * Decoded straight from the stream into typed maps. The file used to be read
 * into one String and parsed into a full JSON tree twice (pubkeys, then
 * vouches); on a low-RAM phone that churn ran during the first seconds of
 * feed scrolling (RESEARCH/NV_MOTO_CHECK_11_01.md #1).
 */
object WotCacheFile {

    /**
     * [pubkeys] as [FeedFilterEngine.parseWotCache] rules them (empty when the
     * graph names only the owner); [vouches] null when the cache predates them.
     */
    data class Parsed(val pubkeys: Set<String>, val vouches: Map<String, Int>?)

    @Serializable
    private class Shape(
        val pubkeys: Map<String, Boolean>? = null,
        val vouches: Map<String, Double>? = null,
    )

    private val json = Json { ignoreUnknownKeys = true }

    /** Null when the content can't be read as the cache (the caller keeps its graph). */
    @OptIn(ExperimentalSerializationApi::class)
    fun read(input: InputStream, ownerHex: String): Parsed? = try {
        val stream = BufferedInputStream(input)
        when (firstToken(stream)) {
            '{' -> {
                val shape = json.decodeFromStream(Shape.serializer(), stream)
                shape.pubkeys?.let { keys ->
                    Parsed(usable(keys.keys, ownerHex), shape.vouches?.mapValues { it.value.toInt() })
                }
            }
            // Tolerate a bare array too, in case an older relay ever wrote one.
            '[' -> Parsed(usable(json.decodeFromStream(ListSerializer(String.serializer()), stream).toSet(), ownerHex), null)
            else -> null
        }
    } catch (_: Exception) {
        null
    }

    fun parse(content: String, ownerHex: String): Parsed? = read(content.byteInputStream(), ownerHex)

    private fun usable(pubkeys: Set<String>, ownerHex: String): Set<String> =
        if (FeedFilterEngine.hasUsableWot(pubkeys, ownerHex)) pubkeys else emptySet()

    /** The first non-blank character, left unread in [stream]. */
    private fun firstToken(stream: BufferedInputStream): Char? {
        while (true) {
            stream.mark(1)
            val b = stream.read()
            if (b < 0) return null
            if (!b.toChar().isWhitespace()) {
                stream.reset()
                return b.toChar()
            }
        }
    }
}
