package com.nostrvault.service

import com.nostrvault.util.findAllOnce
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*

    // ══════════════════════════════════════════════════════════════════
    // Utilities
    // ══════════════════════════════════════════════════════════════════

    fun NostrService.extractMediaURLs(content: String, pubkey: String, tags: List<List<String>>, createdAt: Long = 0L): List<MediaItem> {
        val urls = mutableListOf<MediaItem>()
        val urlRegex = Regex("""https?://\S+\.(jpg|jpeg|png|gif|webp|mp4|mov|webm|mp3|wav|ogg)""", RegexOption.IGNORE_CASE)
        for (match in urlRegex.findAllOnce(content)) {
            val urlStr = match.value
            val ext = urlStr.substringAfterLast('.').lowercase()
            val mediaType = when (ext) {
                "jpg", "jpeg", "png", "gif", "webp" -> MediaType.IMAGE
                "mp4", "mov", "webm" -> MediaType.VIDEO
                "mp3", "wav", "ogg" -> MediaType.AUDIO
                else -> MediaType.UNKNOWN
            }
            urls.add(
                MediaItem(
                    url = urlStr,
                    type = mediaType,
                    pubkey = pubkey,
                    createdAt = createdAt,
                )
            )
        }
        // Also extract from tags (kind 1063 file metadata)
        for (tag in tags) {
            if (tag.size >= 2 && tag[0] == "url") {
                urls.add(
                    MediaItem(
                        url = tag[1],
                        type = MediaType.UNKNOWN,
                        pubkey = pubkey,
                        createdAt = createdAt,
                    )
                )
            }
        }
        return urls
    }

    internal fun NostrService.normalizeRelayUrl(url: String): String {
        return url.trimEnd('/')
    }

    internal fun NostrService.isLocalUrl(url: String): Boolean {
        return url.contains("localhost") || url.contains("127.0.0.1")
    }

    internal fun NostrService.isValidRelayUrl(url: String): Boolean {
        return url.startsWith("wss://") && !url.contains(' ')
    }

    internal fun NostrService.buildFilterJson(filter: Map<String, Any>): String {
        val entries = filter.entries.joinToString(",") { (key, value) ->
            when (value) {
                is String -> "\"$key\":\"$value\""
                is Int -> "\"$key\":$value"
                is Long -> "\"$key\":$value"
                is List<*> -> {
                    val items = value.joinToString(",") { item ->
                        when (item) {
                            is String -> "\"$item\""
                            is Int -> "$item"
                            is Long -> "$item"
                            else -> "\"$item\""
                        }
                    }
                    "\"$key\":[$items]"
                }
                else -> "\"$key\":\"$value\""
            }
        }
        return "{$entries}"
    }

    internal fun NostrService.serializeEvent(event: NostrEvent): String = EventPublisher.serializeSignedEvent(event)
