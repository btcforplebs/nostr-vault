package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.fail
import org.junit.Test

/** A pay_invoice reply counts as paid only with a preimage (Tron, PR 834 re-check). */
class NWCServiceTest {
    private val json = Json { ignoreUnknownKeys = true }
    private fun reply(text: String) = json.decodeFromString<NWCResponse>(text)

    private fun noPreimage(response: NWCResponse) {
        try {
            NWCService.paidPreimage(response); fail("should not count as paid")
        } catch (e: NWCNoPreimageException) {
            assertFalse(e is NWCNotSentException)
        }
    }

    @Test fun aPreimageIsPaid() {
        assertEquals("ab12", NWCService.paidPreimage(reply("""{"result_type":"pay_invoice","result":{"preimage":"ab12"}}""")))
    }

    @Test fun aReplyWithNeitherPreimageNorErrorIsNotPaid() {
        noPreimage(reply("""{"result_type":"pay_invoice","result":{}}"""))
        noPreimage(reply("""{"result_type":"pay_invoice"}"""))
        noPreimage(reply("""{"result_type":"pay_invoice","result":{"preimage":""}}"""))
        noPreimage(reply("""{"result_type":"pay_invoice","result":{"preimage":"  "}}"""))
        noPreimage(NWCResponse(result = mapOf("preimage" to JsonNull)))
        noPreimage(NWCResponse(result = mapOf("preimage" to JsonPrimitive(1))))
    }

    @Test fun aWalletErrorKeepsItsCode() {
        try {
            NWCService.paidPreimage(reply("""{"result_type":"pay_invoice","error":{"code":"INSUFFICIENT_BALANCE","message":"low"}}"""))
            fail("should throw")
        } catch (e: NWCWalletException) {
            assertEquals("INSUFFICIENT_BALANCE", e.code)
        }
    }

    @Test fun aPreimageWinsOverAnErrorInTheSameReply() {
        assertEquals("ab12", NWCService.paidPreimage(
            reply("""{"result":{"preimage":"ab12"},"error":{"code":"INSUFFICIENT_BALANCE","message":"x"}}"""),
        ))
    }

}
