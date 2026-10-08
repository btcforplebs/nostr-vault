package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

/**
 * Vertex's Verify Reputation service (vertexlab.io), the follower count
 * npub.world shows. The app sends a signed kind 5312 request naming the
 * profile; Vertex answers with a kind 6312 whose first entry is that profile,
 * or a kind 7000 error (e.g. a key with no credits). Mirrors iOS
 * VertexReputation.
 * https://vertexlab.io/docs/endpoints/verify-reputation/
 */
object VertexReputation {
    const val RELAY_URL = "wss://relay.vertexlab.io"
    /** The key Vertex signs its answers with. Anything else tagging our request is ignored. */
    const val SERVICE_PUBKEY = "b0565a0d950477811f35ff76e5981ede67a90469a97feec13dc17f36290debfe"

    const val REQUEST_KIND = 5312
    const val RESULT_KIND = 6312
    const val FEEDBACK_KIND = 7000

    fun requestTags(target: String): List<List<String>> = listOf(listOf("param", "target", target))

    sealed interface Reply {
        data class Followers(val count: Int) : Reply
        /** Vertex refused; use the relay count instead. */
        data class Failed(val message: String) : Reply
    }

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Reads one event from Vertex's relay. Null means it isn't the answer to
     * [requestId] (wrong author, wrong request, or a non-final status), so
     * keep waiting.
     */
    fun reply(
        kind: Int, pubkey: String, tags: List<List<String>>, content: String,
        requestId: String, target: String,
    ): Reply? {
        if (pubkey != SERVICE_PUBKEY) return null
        if (tags.none { it.size >= 2 && it[0] == "e" && it[1] == requestId }) return null
        return when (kind) {
            RESULT_KIND -> {
                val first = runCatching { json.parseToJsonElement(content).jsonArray.firstOrNull() as? JsonObject }.getOrNull()
                val followers = first?.get("followers")?.jsonPrimitive?.intOrNull
                if (first?.get("pubkey")?.jsonPrimitive?.contentOrNull != target || followers == null || followers < 0) {
                    Reply.Failed("unreadable result")
                } else {
                    Reply.Followers(followers)
                }
            }
            FEEDBACK_KIND -> {
                val status = tags.firstOrNull { it.size >= 2 && it[0] == "status" }
                if (status == null || status[1] != "error") null
                else Reply.Failed(status.getOrNull(2) ?: "error")
            }
            else -> null
        }
    }

    /**
     * Answers kept for a while so reopening a profile doesn't spend another
     * request, and a pause after a refusal so a key without credits doesn't
     * send every profile it opens to Vertex for nothing.
     */
    class Cache {
        private val answers = HashMap<String, Pair<Int, Long>>()
        private var refusedAtMs: Long? = null

        @Synchronized
        fun followers(target: String, nowMs: Long): Int? {
            val (count, at) = answers[target] ?: return null
            return count.takeIf { nowMs - at < ANSWER_LIFETIME_MS }
        }

        @Synchronized
        fun shouldAsk(nowMs: Long): Boolean {
            val refused = refusedAtMs ?: return true
            return nowMs - refused >= REFUSAL_PAUSE_MS
        }

        @Synchronized
        fun record(reply: Reply, target: String, nowMs: Long) {
            when (reply) {
                is Reply.Followers -> {
                    answers[target] = reply.count to nowMs
                    refusedAtMs = null
                }
                is Reply.Failed -> refusedAtMs = nowMs
            }
        }

        companion object {
            const val ANSWER_LIFETIME_MS = 30 * 60 * 1000L
            const val REFUSAL_PAUSE_MS = 30 * 60 * 1000L
        }
    }
}
