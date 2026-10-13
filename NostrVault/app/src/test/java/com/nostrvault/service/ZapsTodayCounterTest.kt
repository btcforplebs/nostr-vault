package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.relay.HavenConfig
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The counter's trust gate: only a receipt whose signature checks out, and
 * whose publisher may speak for you, is counted. The relay and both checks
 * are stand-ins; the counting is the real [ZapsTodayCounter.count].
 */
class ZapsTodayCounterTest {

    private val me = "a".repeat(64)
    private val now = 1_760_400_000_000L
    private val since = ZapsToday.startOfDay(now)

    private fun receipt(id: String, publisher: String = "zapper") = Json.parseToJsonElement(
        """{"id":"$id","pubkey":"$publisher","kind":9735,"created_at":${since + 60},"tags":[["p","$me"]],"sig":"s-$id"}""",
    ).jsonObject

    private fun counter(
        events: List<JsonObject>,
        answered: Boolean = true,
        signed: (String) -> Boolean,
        publisherOk: (String) -> Boolean = { true },
    ): ZapsTodayCounter {
        val nostr = mockk<NostrService>(relaxed = true)
        every { nostr.profiles } returns MutableStateFlow(emptyMap())
        @Suppress("UNCHECKED_CAST")
        coEvery { nostr.queryRawEvents(any(), any(), any(), any(), any()) } coAnswers {
            if (answered) (args[3] as (() -> Unit)?)?.invoke()
            events
        }
        val config = mockk<ConfigStore>(relaxed = true) {
            every { this@mockk.config } returns MutableStateFlow(HavenConfig(ownerNpub = "npub1me"))
        }
        return ZapsTodayCounter(nostr, config, verify = signed, isValidReceipt = { publisher, _, _ -> publisherOk(publisher) })
    }

    @Test fun onlyReceiptsWhoseSignatureChecksOutCount() = runTest {
        val good = receipt("good")
        val forged = receipt("forged")
        val count = counter(listOf(good, forged), signed = { json -> "\"s-good\"" in json }).count(me, now)
        assertEquals(1, count)
    }

    @Test fun nothingUnsignedCounts() = runTest {
        assertEquals(0, counter(listOf(receipt("x"), receipt("y")), signed = { false }).count(me, now))
    }

    @Test fun aSignedReceiptFromAPublisherThatCantSpeakForYouDoesNotCount() = runTest {
        val count = counter(
            listOf(receipt("real", publisher = "lnurl-service"), receipt("copied", publisher = "someone-else")),
            signed = { true },
            publisherOk = { it == "lnurl-service" },
        ).count(me, now)
        assertEquals(1, count)
    }

    @Test fun noAnswerFromTheRelayIsNoCount() = runTest {
        assertNull(counter(emptyList(), answered = false, signed = { true }).count(me, now))
    }
}
