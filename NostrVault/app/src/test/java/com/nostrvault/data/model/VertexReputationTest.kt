package com.nostrvault.data.model

import com.nostrvault.data.model.VertexReputation.Reply
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VertexReputationTest {

    private val service = VertexReputation.SERVICE_PUBKEY
    private val target = "e2ccf7cf20403f3f2a4a55b328f0de3be38558a7d5f33632fdaaefc726c1c8eb"
    private val requestId = "c863ff5e138695b1684e23e0dd6bb55bd5a17346640798633c31bc97a3371475"

    /** Content of a real kind 6312 from relay.vertexlab.io (2026-10-08), trimmed to two followers. */
    private val realContent = """[{"pubkey":"e2ccf7cf20403f3f2a4a55b328f0de3be38558a7d5f33632fdaaefc726c1c8eb","rank":0.0006655309037957871,"follows":1482,"followers":16270},{"pubkey":"82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2","rank":0.006117609673151461},{"pubkey":"32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245","rank":0.003288825790550474}]"""

    private fun reply(
        kind: Int = VertexReputation.RESULT_KIND,
        pubkey: String = service,
        tags: List<List<String>> = listOf(listOf("e", requestId), listOf("p", "1b8e")),
        content: String = realContent,
        target: String = this.target,
    ) = VertexReputation.reply(kind, pubkey, tags, content, requestId, target)

    @Test fun `request names the target`() {
        assertEquals(listOf(listOf("param", "target", target)), VertexReputation.requestTags(target))
    }

    @Test fun `reads the target's followers from a real result`() {
        assertEquals(Reply.Followers(16270), reply())
    }

    @Test fun `ignores events not from Vertex or for another request`() {
        assertNull(reply(pubkey = "ffff6af836eadef0d20a8891f65e53562e4bea181d38b25797b4ce2f4979d415"))
        assertNull(reply(tags = listOf(listOf("e", "5aa1430e28d4d83c356b350867769cc18ae61b15c2b0a391e6cb0a501da3de54"))))
        assertNull(reply(tags = emptyList()))
    }

    @Test fun `a result for a different profile is not used`() {
        assertEquals(Reply.Failed("unreadable result"), reply(target = "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2"))
        assertEquals(Reply.Failed("unreadable result"), reply(content = "not json"))
    }

    @Test fun `real no-credits error fails`() {
        val tags = listOf(
            listOf("e", requestId), listOf("p", "ff50"),
            listOf("status", "error", "you don't have enough credits to fulfil the request. Send us a DM and we'll give you a top-up for free!"),
        )
        val r = reply(kind = VertexReputation.FEEDBACK_KIND, tags = tags, content = "")
        assertTrue(r is Reply.Failed && r.message.contains("credits"))
    }

    @Test fun `processing status keeps waiting`() {
        assertNull(reply(kind = VertexReputation.FEEDBACK_KIND, tags = listOf(listOf("e", requestId), listOf("status", "processing")), content = ""))
    }

    @Test fun `cache keeps answers for half an hour`() {
        val cache = VertexReputation.Cache()
        val t0 = 1_000_000_000L
        cache.record(Reply.Followers(2754), target, t0)
        assertEquals(2754, cache.followers(target, t0 + 29 * 60_000))
        assertNull(cache.followers(target, t0 + 31 * 60_000))
        assertNull(cache.followers("other", t0))
    }

    @Test fun `a refusal pauses asking for half an hour`() {
        val cache = VertexReputation.Cache()
        val t0 = 1_000_000_000L
        assertTrue(cache.shouldAsk(t0))
        cache.record(Reply.Failed("no credits"), target, t0)
        assertFalse(cache.shouldAsk(t0 + 29 * 60_000))
        assertTrue(cache.shouldAsk(t0 + 30 * 60_000))
    }
}
