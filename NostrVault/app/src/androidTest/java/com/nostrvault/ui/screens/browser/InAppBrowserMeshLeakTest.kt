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
        <iframe src="http://$leak/frame"></iframe><iframe id="blank"></iframe>
        <video src="/clip.mp4" preload="auto" muted></video><video src="http://$leak/clip.mp4" preload="auto" muted></video>
        <form id="f" method="post" action="http://$leak/post"><input name="a" value="1"></form>
        <script>
        var r = [];
        try { fetch('http://$leak/fetch').catch(function () {}); } catch (e) {}
        try { var x = new XMLHttpRequest(); x.open('GET', 'http://$leak/xhr'); x.send(); } catch (e) {}
        try { new WebSocket('ws://$leak/ws'); } catch (e) {}
        try { new WebSocket('ws://$npub.fips/ws'); r.push('fipsws-made'); } catch (e) { r.push('fipsws-refused'); }
        r.push('rtc-' + typeof RTCPeerConnection);
        try { var pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:$leak' }] }); pc.createDataChannel('x'); pc.createOffer().then(function (o) { return pc.setLocalDescription(o); }); } catch (e) {}
        try { navigator.sendBeacon('http://$leak/beacon', 'x'); } catch (e) {}
        try { new EventSource('http://$leak/es'); } catch (e) {}
        try { var l = document.createElement('link'); l.rel = 'preconnect'; l.href = 'http://$leak/'; document.head.appendChild(l); } catch (e) {}
        // Frames the page makes reach their window without contentWindow: each must have no WebRTC either.
        var stun = { iceServers: [{ urls: 'stun:$leak' }] };
        // An offer starts ICE gathering: the STUN request a site would use to learn this device's IP.
        function offer(pc, tag) { pc.createDataChannel(tag); pc.createOffer().then(function (o) { return pc.setLocalDescription(o); }).catch(function () {}); }
        function rtc(tag, w) {
          try { r.push(tag + '-' + typeof w.RTCPeerConnection); if (w.RTCPeerConnection) offer(new w.RTCPeerConnection(stun), tag); }
          catch (e) { r.push(tag + '-err'); }
        }
        try {
          var f = document.createElement('iframe'); document.body.appendChild(f);
          rtc('frames', frames[frames.length - 1]);
          rtc('index', window[window.length - 1]);
          rtc('doc', f.contentDocument.defaultView);
          var g = document.createElement('iframe'); document.body.appendChild(g);
          g.contentDocument.open(); g.contentDocument.write('<p>w</p>'); g.contentDocument.close();
          rtc('written', g.contentDocument.defaultView);
          rtc('static', document.getElementById('blank').contentDocument.defaultView);
          var d = document.createElement('div'); document.body.appendChild(d); d.innerHTML = '<iframe></iframe>';
          rtc('html', window[window.length - 1]);
          var host = document.createElement('div'); document.body.appendChild(host);
          host.attachShadow({ mode: 'closed' }).appendChild(document.createElement('iframe'));
          rtc('shadow', window[window.length - 1]);
          // A page that breaks the tools the guard would use, then makes a frame.
          Object.defineProperty = function () {}; Event.prototype.stopImmediatePropagation = function () {};
          String.prototype.toLowerCase = function () { return 'web'; };
          var p = document.createElement('iframe'); document.body.appendChild(p);
          rtc('poisoned', window[window.length - 1]);
        } catch (e) { r.push('frames-err:' + e); }
        // Frames whose own script runs: srcdoc (same origin) and sandboxed srcdoc (opaque origin, no top access).
        window.addEventListener('message', function (e) { if (typeof e.data === 'string' && e.data.indexOf('in-') === 0) r.push(e.data); });
        var inner = "<script>var s='undefined';try{s=typeof RTCPeerConnection;if(window.RTCPeerConnection){var p=new RTCPeerConnection({iceServers:[{urls:'stun:$leak'}]});p.createDataChannel('i');p.createOffer().then(function(o){return p.setLocalDescription(o)})}}catch(e){s='err'}parent.postMessage('in-'+name+'-'+s,'*')<\/script>";
        [['srcdoc', ''], ['sandboxed', 'allow-scripts']].forEach(function (k) {
          var i = document.createElement('iframe'); i.name = k[0]; if (k[1]) i.setAttribute('sandbox', k[1]); i.srcdoc = inner; document.body.appendChild(i);
        });
        try {
          var j = document.createElement('iframe'); j.name = 'js'; j.src = 'javascript:"' + inner.replace(/"/g, '&quot;') + '"'; document.body.appendChild(j);
        } catch (e) { r.push('in-js-err'); }
        // A frame sent to about:blank again after it was made: a new document in the same window.
        try {
          var n = document.createElement('iframe'); document.body.appendChild(n);
          n.onload = function () { rtc('renav', n.contentWindow); }; n.src = 'about:blank';
        } catch (e) { r.push('renav-err'); }
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
        for (frame in listOf("frames", "index", "doc", "written", "static", "html", "shadow", "poisoned", "renav", "in-srcdoc", "in-sandboxed", "in-js")) {
            assertTrue("WebRTC is gone in the page's $frame frame ($t), leaks: $leaks", t.contains("$frame-undefined"))
        }
        assertTrue("a websocket to a .fips host is refused before DNS ($t)", t.contains("fipsws-refused"))
        assertTrue("the page's own stylesheet came over the mesh: $doorPaths", "/style.css" in doorPaths)
        assertTrue("another npub's image was not read for this page: $doorPaths", doorPaths.none { it.contains("other") })
        assertEquals("nothing reached the internet host: $leaks", emptyList<String>(), leaks.toList())

        // Positive control: the same host as a web page the reader asked for does connect.
        onMain { model.open("http://$leak/control") }
        assertTrue("the counter sees a real connection", waitForLeak())
    }

    @Test fun aSecondBrowserCannotTurnTheMeshProxyOffUnderAMeshPage() {
        onMain { model.open("http://$npub.fips/") }
        assertTrue("the mesh page ran (title: ${title()})", waitFor(20_000) { model.title.startsWith("done:") })
        Thread.sleep(1500)
        assertEquals("the mesh page itself reached nothing: $leaks", emptyList<String>(), leaks.toList())

        // A second browser over the first, on a web page, then closed: the first is on screen again.
        val web = MockWebServer().apply {
            dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest) =
                    MockResponse().setHeader("Content-Type", "text/html").setBody("<title>web-page</title><p>web</p>")
            }
            start()
        }
        lateinit var second: InAppBrowserModel
        onMain {
            model.pause()
            second = InAppBrowserModel(instrumentation.targetContext) { error("no mesh in the second browser") }
            second.resume()
            second.open("http://127.0.0.1:${web.port}/")
        }
        assertTrue("the second browser loaded its web page", waitFor(10_000) { second.title == "web-page" })
        onMain { second.close(); model.resume() }
        web.shutdown()

        // The mesh page adds a preconnect after the reader came back.
        onMain {
            model.webView.evaluateJavascript(
                "var l=document.createElement('link');l.rel='preconnect';l.href='http://$leak/';document.head.appendChild(l);" +
                    "var i=new Image();i.src='http://$leak/back.png'", null)
        }
        Thread.sleep(3000)
        assertEquals("nothing reached the internet host after the second browser: $leaks", emptyList<String>(), leaks.toList())

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
