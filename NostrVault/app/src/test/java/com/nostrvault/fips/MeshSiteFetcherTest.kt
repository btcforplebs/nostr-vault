package com.nostrvault.fips

import com.nostrvault.fips.MeshSiteFetcher.Reply
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.TimeUnit

/** A `.fips` page read through a stand-in door: token path, Host, redirects, caps and the reasons a page fails. */
class MeshSiteFetcherTest {
    private val npub = "npub1z2g42utgkc5tv49xgwy7lplfd8048vuwv9krcc23m828kdjm3cl68tgcyy"
    private val site = "http://$npub.fips/blog/?p=1"
    private lateinit var server: MockWebServer
    private lateinit var base: String

    @Before fun up() {
        server = MockWebServer().apply { start() }
        base = "http://127.0.0.1:${server.port}/tok3n"
    }

    @After fun down() = server.shutdown()

    private fun fetcher(door: (String) -> MeshSiteIngress = { MeshSiteIngress.Ready(base) }) =
        MeshSiteFetcher(door, treeWaitMs = 300, treePollMs = 50)

    private fun Reply.html() = (this as Reply.Page).html

    @Test fun aPageIsReadThroughTheDoorUnderItsOwnName() {
        server.enqueue(MockResponse().setBody("<h1>hi</h1>").setHeader("Content-Type", "text/html; charset=utf-8")
            .setHeader("Set-Cookie", "a=1"))
        val reply = fetcher().fetch(npub, site, "GET", isMain = true) as Reply.Body
        val req = server.takeRequest(2, TimeUnit.SECONDS)!!
        assertEquals("/tok3n/blog/?p=1", req.path)
        assertEquals("$npub.fips", req.getHeader("Host"))
        assertEquals(200, reply.status)
        assertEquals("text/html", reply.mime)
        assertEquals("UTF-8", reply.charset)
        assertNull(reply.headers["Set-Cookie"])
        assertTrue(reply.headers["Content-Security-Policy"]!!.contains("connect-src http://$npub.fips;"))
        assertEquals("<h1>hi</h1>", reply.stream.readBytes().decodeToString())
    }

    @Test fun aRedirectOnTheSiteMovesThePageAndOneOffItIsSaidNotFollowed() {
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "/new"))
        val same = fetcher().fetch(npub, site, "GET", isMain = true).html()
        assertTrue(same.contains("url=http://$npub.fips/new"))
        server.enqueue(MockResponse().setResponseCode(301).setHeader("Location", "https://tracker.example/x"))
        val off = fetcher().fetch(npub, site, "GET", isMain = true).html()
        assertTrue("an off-mesh redirect is a page with a link, not a load", off.contains("Open on the web") && !off.contains("http-equiv"))
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "http://site.fips/"))
        assertTrue(fetcher().fetch(npub, site, "GET", isMain = true).html().contains(FipsUrl.htmlEscaped(MeshPage.Refused.title)))
    }

    @Test fun aSubresourceFollowsItsSitesRedirectsOnly() {
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "/b.png"))
        server.enqueue(MockResponse().setBody("png"))
        val ok = fetcher().fetch(npub, "http://$npub.fips/a.png", "GET", isMain = false) as Reply.Body
        assertEquals("png", ok.stream.readBytes().decodeToString())
        server.takeRequest(); assertEquals("/tok3n/b.png", server.takeRequest().path)
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "https://cdn.example/b.png"))
        assertEquals(Reply.Fail, fetcher().fetch(npub, "http://$npub.fips/a.png", "GET", isMain = false))
    }

    @Test fun formsAreNotSentAnywhere() {
        val reply = fetcher().fetch(npub, site, "POST", isMain = true) as Reply.Page
        assertEquals(405, reply.status)
        assertEquals(0, server.requestCount)
    }

    @Test fun aSiteThatDoesNotAnswerIsSaidSo() {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))
        assertTrue(fetcher().fetch(npub, site, "GET", isMain = true).html().contains(FipsUrl.htmlEscaped(MeshPage.Unreachable.title)))
    }

    @Test fun aPageTooBigForTheCapIsRefused() {
        server.enqueue(MockResponse().setBody("").setHeader("Content-Length", MeshSiteFetcher.PAGE_BYTE_CAP + 1))
        // The declared length alone answers: MockWebServer would otherwise stall on the missing bytes.
        assertTrue(fetcher().fetch(npub, site, "GET", isMain = true).html().contains(FipsUrl.htmlEscaped(MeshPage.TooBig.title)))
    }

    @Test fun theMeshWaitsForItsTreeThenSaysWhy() {
        var asks = 0
        var status: String? = "unset"
        val f = fetcher { asks++; MeshSiteIngress.NotReady }
        f.onStatus = { status = it }
        assertTrue(f.fetch(npub, site, "GET", isMain = true).html().contains(FipsUrl.htmlEscaped(MeshPage.NotReady.title)))
        assertTrue("it asked again while waiting", asks > 1)
        assertNull("the status clears", status)
        assertTrue(fetcher { MeshSiteIngress.MeshOff }.fetch(npub, site, "GET", isMain = true).html().contains(FipsUrl.htmlEscaped(MeshPage.MeshOff.title)))
        assertEquals(Reply.Fail, fetcher { MeshSiteIngress.MeshOff }.fetch(npub, site, "GET", isMain = false))
    }

    @Test fun ingressCodesReadAsTheBrowserSaysThem() {
        assertEquals(MeshSiteIngress.NotReady, MeshSiteIngress.fromCode(FipsBridge.ERR_NO_TREE))
        assertEquals("no seeds: no tree will ever come", MeshSiteIngress.NoSeeds, MeshSiteIngress.fromCode(-10, publicSeeds = false))
        assertEquals(MeshSiteIngress.EngineOff, MeshSiteIngress.fromCode(FipsBridge.ERR_NOT_RUNNING))
        for (rc in listOf(-1, -5, -6, -9, -11)) assertEquals("rc $rc", MeshSiteIngress.Failed, MeshSiteIngress.fromCode(rc))
    }
}
