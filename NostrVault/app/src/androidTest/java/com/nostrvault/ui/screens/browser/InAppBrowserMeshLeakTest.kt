package com.nostrvault.ui.screens.browser

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.nostrvault.fips.MeshSiteIngress
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.ServerSocket
import java.util.Collections
import kotlin.concurrent.thread

/**
 * A hostile `.fips` page in the real WebView: everything it tries to reach off its own site must arrive nowhere.
 *
 * The "internet" is a socket on this device (TCP and UDP on one port) that records every connection. The door is
 * a stand-in for `NvFipsIngress`. The last step loads that socket as a web page, so the counter is shown to work:
 * a leak test that can't see a leak proves nothing.
 */
@RunWith(AndroidJUnit4::class)
class InAppBrowserMeshLeakTest {
    // A random string in the npub charset, not a real account.
    private val npub = "npub1z2g42utgkc5tv49xgwy7lplfd8048vuwv9krcc23m828kdjm3cl68tgcyy"
    private val other = "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private lateinit var door: MockWebServer
    private val doorPaths = Collections.synchronizedList(mutableListOf<String>())
    private lateinit var tcp: ServerSocket
    private lateinit var udp: DatagramSocket
    private val leaks = Collections.synchronizedList(mutableListOf<String>())
    private lateinit var model: InAppBrowserModel

    private val leak get() = "127.0.0.1:${tcp.localPort}"

    private fun meshPage() = """
        <!doctype html><html><head>
        <link rel="preconnect" href="http://$leak/">
        <link rel="dns-prefetch" href="http://$leak/">
        <link rel="prefetch" href="http://$leak/prefetch">
        <link rel="stylesheet" href="/style.css">
        <link rel="stylesheet" href="http://$leak/style.css">
        <script src="http://$leak/x.js"></script>
        <style>body{background:url(http://$leak/bg.png)} @font-face{font-family:f;src:url(http://$leak/f.woff)} p{font-family:f}</style>
        </head><body><p>mesh</p>
        <img src="http://$leak/img.png"><img src="http://$other.fips/other.png"><img src="/own.png">
        <iframe src="http://$leak/frame"></iframe>
        <video src="/clip.mp4" preload="auto" muted></video><video src="http://$leak/clip.mp4" preload="auto" muted></video>
        <form id="f" method="post" action="http://$leak/post"><input name="a" value="1"></form>
        <script>
        var r = [];
        try { fetch('http://$leak/fetch').catch(function () {}); } catch (e) {}
        try { var x = new XMLHttpRequest(); x.open('GET', 'http://$leak/xhr'); x.send(); } catch (e) {}
        try { new WebSocket('ws://$leak/ws'); } catch (e) {}
        try { new WebSocket('ws://$npub.fips/ws'); r.push('fipsws-made'); } catch (e) { r.push('fipsws-refused'); }
        r.push('rtc-' + typeof RTCPeerConnection);
        try { new RTCPeerConnection({ iceServers: [{ urls: 'stun:$leak' }] }).createDataChannel('x'); } catch (e) {}
        try { navigator.sendBeacon('http://$leak/beacon', 'x'); } catch (e) {}
        try { new EventSource('http://$leak/es'); } catch (e) {}
        try { var l = document.createElement('link'); l.rel = 'preconnect'; l.href = 'http://$leak/'; document.head.appendChild(l); } catch (e) {}
        setTimeout(function () { document.title = 'done:' + r.join(','); }, 1500);
        </script></body></html>
    """.trimIndent()

    @Before fun up() {
        tcp = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
        thread(isDaemon = true) {
            while (!tcp.isClosed) {
                val s = runCatching { tcp.accept() }.getOrNull() ?: break
                thread(isDaemon = true) {
                    s.use {
                        it.soTimeout = 2000
                        val line = runCatching { it.getInputStream().bufferedReader().readLine() }.getOrNull()
                        leaks += "tcp " + (line ?: "(no request line)")
                        runCatching { it.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray()) }
                    }
                }
            }
        }
        udp = DatagramSocket(tcp.localPort, InetAddress.getByName("127.0.0.1"))
        thread(isDaemon = true) {
            val p = DatagramPacket(ByteArray(1500), 1500)
            while (!udp.isClosed) { if (runCatching { udp.receive(p) }.isSuccess) leaks += "udp ${p.length} bytes" }
        }
        door = MockWebServer().apply {
            dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    val path = request.path!!.removePrefix("/tok")
                    doorPaths += path
                    assertEquals("$npub.fips", request.getHeader("Host"))
                    return when (path) {
                        "/" -> MockResponse().setHeader("Content-Type", "text/html; charset=utf-8")
                            .setHeader("Link", "<http://$leak/>; rel=preconnect").setBody(meshPage())
                        "/style.css" -> MockResponse().setHeader("Content-Type", "text/css").setBody("p{color:red}")
                        else -> MockResponse().setResponseCode(404)
                    }
                }
            }
            start()
        }
        val base = "http://127.0.0.1:${door.port}/tok"
        instrumentation.runOnMainSync {
            model = InAppBrowserModel(instrumentation.targetContext) { MeshSiteIngress.Ready(base) }
        }
    }

    @After fun down() {
        instrumentation.runOnMainSync { model.close() }
        door.shutdown(); tcp.close(); udp.close()
    }

    private fun onMain(block: () -> Unit) = instrumentation.runOnMainSync(block)

    private fun waitFor(ms: Long, what: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < end) {
            var ok = false
            onMain { ok = what() }
            if (ok) return true
            Thread.sleep(100)
        }
        return false
    }

    private fun title(): String { var t = ""; onMain { t = model.title }; return t }

    @Test fun aMeshPageReachesNoInternetHostByItself() {
        onMain { model.open("http://$npub.fips/") }
        assertTrue("the mesh page ran (title: ${title()})", waitFor(20_000) { model.title.startsWith("done:") })
        assertEquals(InAppBrowserModel.Kind.Mesh, run { var k = InAppBrowserModel.Kind.Web; onMain { k = model.kind }; k })
        // A form post, a script navigation and a refresh off the mesh: none may go.
        onMain { model.webView.evaluateJavascript("document.getElementById('f').submit()", null) }
        Thread.sleep(1500)
        onMain { model.open("http://$npub.fips/") }
        waitFor(10_000) { model.title.startsWith("done:") }
        onMain { model.webView.evaluateJavascript("location.href='http://$leak/script-nav'", null) }
        Thread.sleep(1500)
        onMain { model.open("http://$npub.fips/") }
        waitFor(10_000) { model.title.startsWith("done:") }
        onMain { model.webView.evaluateJavascript("var m=document.createElement('meta');m.httpEquiv='refresh';m.content='0;url=http://$leak/refresh';document.head.appendChild(m)", null) }
        Thread.sleep(3000)

        val t = title()
        assertTrue("WebRTC is gone on a mesh page ($t)", t.contains("rtc-undefined"))
        assertTrue("a websocket to a .fips host is refused before DNS ($t)", t.contains("fipsws-refused"))
        assertTrue("the page's own stylesheet came over the mesh: $doorPaths", "/style.css" in doorPaths)
        assertTrue("another npub's image was not read for this page: $doorPaths", doorPaths.none { it.contains("other") })
        assertEquals("nothing reached the internet host: $leaks", emptyList<String>(), leaks.toList())

        // Positive control: the same host as a web page the reader asked for does connect.
        onMain { model.open("http://$leak/control") }
        assertTrue("the counter sees a real connection", waitForLeak())
    }

    @Test fun aWebPageCannotReachAFipsHost() {
        onMain {
            model.webView.loadDataWithBaseURL("https://example.invalid/", """
                <img src="http://$npub.fips/web-embed.png"><script>
                var r=[]; try { new WebSocket('wss://$npub.fips/'); r.push('made'); } catch (e) { r.push('refused'); }
                setTimeout(function(){ document.title = 'web:' + r.join(','); }, 800);
                </script>
            """.trimIndent(), "text/html", "utf-8", null)
        }
        assertTrue(waitFor(10_000) { model.title.startsWith("web:") })
        assertTrue("a web page's .fips socket is refused (${title()})", title().contains("refused"))
        assertTrue("a web page can't make the engine read an npub: $doorPaths", doorPaths.isEmpty())
    }

    private fun waitForLeak(): Boolean {
        val end = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < end) { if (leaks.isNotEmpty()) return true; Thread.sleep(100) }
        return false
    }
}
