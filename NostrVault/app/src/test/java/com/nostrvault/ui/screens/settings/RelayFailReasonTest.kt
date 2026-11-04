package com.nostrvault.ui.screens.settings

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.EOFException
import java.io.IOException
import java.net.ConnectException
import java.net.ProtocolException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLHandshakeException

/** The Relays page says why a relay didn't connect (NDK check item 4, Logen 2026-11-04). Same words as iOS. */
class RelayFailReasonTest {
    @Test
    fun httpAnswersToTheUpgrade() {
        val refused = ProtocolException("Expected HTTP 101 response but was '403 Forbidden'")
        assertEquals("refused (HTTP 403)", RelayFailReason.text(403, refused))
        assertEquals("refused (HTTP 401)", RelayFailReason.text(401, null))
        assertEquals("no relay at this address (HTTP 404)", RelayFailReason.text(404, null))
        assertEquals("rate-limited (HTTP 429)", RelayFailReason.text(429, null))
        assertEquals("server error (HTTP 502)", RelayFailReason.text(502, null))
        assertEquals("not a relay (answered with a web page)", RelayFailReason.text(200, null))
        assertEquals("HTTP 418", RelayFailReason.text(418, null))
    }

    @Test
    fun upgradedThenFailedReadsTheError() {
        assertEquals("connection dropped", RelayFailReason.text(101, EOFException()))
    }

    @Test
    fun networkErrorsThroughTheCauseChain() {
        assertEquals("no such host", RelayFailReason.text(null, UnknownHostException("relay.nowhere")))
        assertEquals("connection refused", RelayFailReason.text(null, ConnectException()))
        assertEquals("timed out", RelayFailReason.text(null, SocketTimeoutException()))
        assertEquals("certificate problem", RelayFailReason.text(null, IOException("wrapped", SSLHandshakeException("bad cert"))))
        assertEquals("certificate problem", RelayFailReason.text(null, RelayProbeFailure(null, SSLHandshakeException("x"))))
        assertEquals("not answering", RelayFailReason.text(null, IOException("?")))
        assertEquals("not answering", RelayFailReason.text(null, null))
        assertEquals("no answer in 6 s", RelayFailReason.noAnswer(6))
    }
}
