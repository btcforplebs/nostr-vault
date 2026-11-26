package com.nostrvault.fips

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ServerSocket
import java.util.concurrent.TimeUnit

/** A link whose probe fails says which step failed and what came back, never the address (Tod, nv-android ff220e33). */
class MeshCopyStarterProbeTest {
    private val token = "ab".repeat(16)
    private val client = OkHttpClient.Builder().connectTimeout(2, TimeUnit.SECONDS).readTimeout(2, TimeUnit.SECONDS).build()

    private fun url(server: MockWebServer) = "ws://127.0.0.1:${server.port}/$token"

    @Test fun answeredLinkIsNoFailure() {
        MockWebServer().use { s ->
            s.enqueue(MockResponse().setResponseCode(200).setBody("{\"name\":\"Haven\"}"))
            assertNull(MeshCopyStarter.probeFailure(url(s), client))
            assertEquals("/$token", s.takeRequest().path)
        }
    }

    @Test fun refusalNamesStatusAndBodyHead() {
        MockWebServer().use { s ->
            s.enqueue(MockResponse().setResponseCode(403).setBody("blocked: not your device\n" + "x".repeat(500)))
            val line = MeshCopyStarter.probeFailure(url(s), client)!!
            assertTrue(line, line.startsWith("probe answered 403, body \"blocked: not your device x"))
            assertTrue(line, line.length < 200)
        }
    }

    @Test fun noAnswerNamesTheError() {
        val port = ServerSocket(0).use { it.localPort }  // closed: nothing listens
        val line = MeshCopyStarter.probeFailure("ws://127.0.0.1:$port/$token", client)!!
        assertTrue(line, line.startsWith("probe got no answer ("))
    }

    @Test fun neverLogsTheToken() {
        MockWebServer().use { s ->
            s.enqueue(MockResponse().setResponseCode(404).setBody("no route /$token"))
            val line = MeshCopyStarter.probeFailure(url(s), client)!!
            assertFalse(line, line.contains(token))
        }
    }
}
