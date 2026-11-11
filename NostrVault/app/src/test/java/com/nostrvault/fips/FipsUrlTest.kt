package com.nostrvault.fips

import com.nostrvault.fips.FipsUrl.Navigation
import com.nostrvault.fips.FipsUrl.Request
import com.nostrvault.fips.FipsUrl.Route
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URLEncoder

/**
 * The in-app browser's `.fips` addresses: what opens over the mesh, what opens on the web, and that a `.fips` URL
 * never falls through to DNS. Parity with HavenApp FipsURLTests.swift, on Android's real-origin shape.
 */
class FipsUrlTest {
    // A random string in the npub charset, not a real account.
    private val npub = "npub1z2g42utgkc5tv49xgwy7lplfd8048vuwv9krcc23m828kdjm3cl68tgcyy"
    private val other = "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
    private val base = "http://127.0.0.1:41234/abcdef0123456789"

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")

    @Test fun fipsHostsAreRecognisedWhateverTheName() {
        assertTrue(FipsUrl.isFipsHost("$npub.fips"))
        assertTrue(FipsUrl.isFipsHost("${npub.uppercase()}.FIPS"))
        assertTrue("a hosts-file name is still .fips: it must not reach DNS", FipsUrl.isFipsHost("site.fips"))
        assertTrue(FipsUrl.isFipsHost("$npub.fips."))
        assertFalse(FipsUrl.isFipsHost("fips.example.com"))
        assertFalse(FipsUrl.isFipsHost("example.fipsx"))
        assertFalse(FipsUrl.isFipsHost(null))
        assertEquals(npub, FipsUrl.npubInFipsHost("$npub.fips"))
        assertEquals(npub, FipsUrl.npubInFipsHost("${npub.uppercase()}.Fips"))
        assertNull(FipsUrl.npubInFipsHost("site.fips"))
        assertNull("a truncated npub is not one", FipsUrl.npubInFipsHost("${npub.dropLast(1)}.fips"))
    }

    @Test fun aSiteKeepsItsRealOriginInPlainHttp() {
        val site = "http://$npub.fips/blog/a%20b.html?x=1&y=%2F#top"
        assertEquals(site, FipsUrl.siteUrl(site))
        assertEquals("http://$npub.fips/", FipsUrl.siteUrl("http://$npub.fips"))
        assertEquals("https is read as http: the mesh session is the encryption", "http://$npub.fips/a", FipsUrl.siteUrl("https://$npub.fips/a"))
        assertEquals("http://$npub.fips/a", FipsUrl.siteUrl("http://$npub.fips:80/a"))
        assertEquals("http://$npub.fips/", FipsUrl.siteUrl("http://user:pw@$npub.fips/"))
        assertEquals("http://$npub.fips/", FipsUrl.siteUrl("http://${npub.uppercase()}.FIPS./"))
    }

    @Test fun onlyTheDoorsPortAndNpubHostsMap() {
        assertNull("the door serves port 80 only", FipsUrl.siteUrl("http://$npub.fips:8080/"))
        assertNull(FipsUrl.siteUrl("http://site.fips/"))
        assertNull(FipsUrl.siteUrl("http://example.com/"))
        assertNull(FipsUrl.siteUrl("ftp://$npub.fips/"))
        assertNull(FipsUrl.meshNpub("https://example.com/"))
        assertEquals(npub, FipsUrl.meshNpub("http://$npub.fips/x"))
    }

    @Test fun theDoorRequestKeepsTheTokenAndThePath() {
        assertEquals("$base/css/site.css?v=2", FipsUrl.doorUrl(base, "http://$npub.fips/css/site.css?v=2#x"))
        assertEquals("$base/", FipsUrl.doorUrl("$base/", "http://$npub.fips"))
        assertEquals("encoded path bytes pass through as they are", "$base/a%2Fb", FipsUrl.doorUrl(base, "http://$npub.fips/a%2Fb"))
        assertNull("only a loopback door", FipsUrl.doorUrl("http://example.com/t", "http://$npub.fips/"))
        assertNull(FipsUrl.doorUrl(base, "http://example.com/"))
        assertEquals("$npub.fips", FipsUrl.hostHeader("http://$npub.fips/a"))
    }

    @Test fun redirectsStayOnTheMeshOrLeaveItOpenly() {
        val page = "http://$npub.fips/old/page"
        assertEquals("http://$npub.fips/new", FipsUrl.redirectTarget("/new", page))
        assertEquals("http://$npub.fips/old/next", FipsUrl.redirectTarget("next", page))
        assertEquals("http://$npub.fips/x", FipsUrl.redirectTarget("https://$npub.fips/x", page))
        assertEquals("https://example.com/", FipsUrl.redirectTarget("https://example.com/", page))
        assertNull("an unservable .fips target never reaches DNS", FipsUrl.redirectTarget("http://site.fips/", page))
        assertNull(FipsUrl.redirectTarget("http://$npub.fips:8443/", page))
        assertNull(FipsUrl.redirectTarget("javascript:alert(1)", page))
    }

    @Test fun linkTapsRouteByHost() {
        val site = "http://$npub.fips/"
        assertEquals(Route.Mesh(site), FipsUrl.route(site, inApp = true))
        assertEquals("with the toggle off a .fips link still never goes to the system browser", Route.Mesh(site), FipsUrl.route(site, inApp = false))
        assertEquals(Route.Mesh(site), FipsUrl.route("https://$npub.fips", inApp = false))
        assertEquals(Route.RefusedFips, FipsUrl.route("http://site.fips/", inApp = true))
        assertEquals(Route.RefusedFips, FipsUrl.route("http://site.fips/", inApp = false))
        assertEquals(Route.RefusedFips, FipsUrl.route("http://$npub.fips:8080/", inApp = false))
        assertEquals(Route.Web("https://example.com/a"), FipsUrl.route("https://example.com/a", inApp = true))
        assertEquals(Route.Web("http://example.com/a"), FipsUrl.route("http://example.com/a", inApp = true))
        assertEquals(Route.System, FipsUrl.route("https://example.com/a", inApp = false))
        assertEquals(Route.System, FipsUrl.route("mailto:a@example.com", inApp = true))
        assertEquals(Route.System, FipsUrl.route("lightning:lnbc1", inApp = true))
        assertEquals(Route.System, FipsUrl.route("nostr:npub1abc", inApp = true))
    }

    @Test fun nothingInsideThePageReachesAFipsHostOverTheNetwork() {
        val site = "http://$npub.fips/a"
        assertEquals(Navigation.Allow, FipsUrl.navigation(site, isMainFrame = true, fromMesh = false))
        assertEquals(Navigation.Load(site), FipsUrl.navigation("https://$npub.fips/a", isMainFrame = true, fromMesh = false))
        assertEquals("a .fips frame is refused, not loaded", Navigation.Refuse, FipsUrl.navigation(site, isMainFrame = false, fromMesh = false))
        assertEquals(Navigation.Refuse, FipsUrl.navigation("ws://$npub.fips/", isMainFrame = true, fromMesh = false))
        assertEquals(Navigation.Refuse, FipsUrl.navigation("https://site.fips/", isMainFrame = true, fromMesh = false))
        assertEquals(Navigation.Allow, FipsUrl.navigation("https://example.com/", isMainFrame = false, fromMesh = false))
        assertEquals(Navigation.Allow, FipsUrl.navigation("about:blank", isMainFrame = true, fromMesh = false))
        assertEquals(Navigation.Refuse, FipsUrl.navigation("data:text/html,hi", isMainFrame = true, fromMesh = false))
        assertEquals(Navigation.Refuse, FipsUrl.navigation("intent://x#Intent;end", isMainFrame = true, fromMesh = false))
        assertEquals(Navigation.Refuse, FipsUrl.navigation("file:///sdcard/a", isMainFrame = true, fromMesh = false))
        assertEquals(Navigation.External, FipsUrl.navigation("nostr:npub1abc", isMainFrame = true, fromMesh = false))
        assertEquals(Navigation.External, FipsUrl.navigation("lightning:lnbc1", isMainFrame = true, fromMesh = false))
    }

    @Test fun aMeshPageReachesNoInternetHostByItself() {
        val web = "https://owner.example/b"
        assertEquals("a page leave waits for the reader", Navigation.LeaveMesh(web), FipsUrl.navigation(web, isMainFrame = true, fromMesh = true))
        val leave = "nvleave:" + enc(web)
        assertEquals("a clicked link, handed over", Navigation.LeaveMesh(web), FipsUrl.navigation(leave, isMainFrame = true, fromMesh = true))
        assertEquals(Navigation.Refuse, FipsUrl.navigation(leave, isMainFrame = false, fromMesh = true))
        val fipsLeave = "nvleave:" + enc("http://$npub.fips/a")
        assertEquals(Navigation.Load("http://$npub.fips/a"), FipsUrl.navigation(fipsLeave, isMainFrame = true, fromMesh = true))
        assertEquals(Navigation.Refuse, FipsUrl.navigation("nvleave:javascript%3Aalert(1)", isMainFrame = true, fromMesh = true))
        assertEquals(Navigation.Refuse, FipsUrl.navigation("nvleave:nostr%3Anpub1abc", isMainFrame = true, fromMesh = true))
        assertEquals("a frame off the mesh is refused", Navigation.Refuse, FipsUrl.navigation(web, isMainFrame = false, fromMesh = true))
        assertEquals(Navigation.Refuse, FipsUrl.navigation("wss://owner.example/s", isMainFrame = true, fromMesh = true))
        assertEquals(Navigation.Allow, FipsUrl.navigation("http://$npub.fips/x", isMainFrame = true, fromMesh = true))
        assertEquals("web to web is a browser", Navigation.Allow, FipsUrl.navigation(web, isMainFrame = true, fromMesh = false))
    }

    @Test fun everyRequestOnAMeshPageStaysOnItsSite() {
        val site = "http://$npub.fips/img.png"
        assertEquals(Request.Mesh(npub, site), FipsUrl.request(site, isMainFrame = false, meshPage = npub, allowedTopLevel = false))
        assertEquals(Request.Mesh(npub, "http://$npub.fips/"), FipsUrl.request("https://$npub.fips", isMainFrame = true, meshPage = null, allowedTopLevel = false))
        assertEquals("another npub's assets stay off a mesh page", Request.Block,
            FipsUrl.request("http://$other.fips/x", isMainFrame = false, meshPage = npub, allowedTopLevel = false))
        for (u in listOf("https://cdn.example/a.js", "http://10.0.2.2:9/p", "wss://relay.example/")) {
            assertEquals("a mesh page would reach $u", Request.Block, FipsUrl.request(u, isMainFrame = false, meshPage = npub, allowedTopLevel = false))
        }
        assertEquals("a top-level leave the app did not ask for (a form POST, a script) is blocked", Request.Block,
            FipsUrl.request("https://evil.example/", isMainFrame = true, meshPage = npub, allowedTopLevel = false))
        assertEquals(Request.Pass, FipsUrl.request("https://ok.example/", isMainFrame = true, meshPage = npub, allowedTopLevel = true))
        assertEquals(Request.Pass, FipsUrl.request("data:image/png;base64,AA", isMainFrame = false, meshPage = npub, allowedTopLevel = false))
    }

    @Test fun aWebPageCannotMakeTheEngineDialAnyone() {
        assertEquals(Request.Block, FipsUrl.request("http://$npub.fips/x.png", isMainFrame = false, meshPage = null, allowedTopLevel = false))
        assertEquals(Request.Block, FipsUrl.request("http://site.fips/", isMainFrame = true, meshPage = null, allowedTopLevel = true))
        assertEquals(Request.Block, FipsUrl.request("http://$npub.fips:8080/", isMainFrame = true, meshPage = null, allowedTopLevel = true))
        assertEquals(Request.Pass, FipsUrl.request("https://example.com/a.png", isMainFrame = false, meshPage = null, allowedTopLevel = false))
    }

    @Test fun meshRepliesCarryAPolicyThatKeepsThemOnTheSite() {
        val headers = FipsUrl.meshHeaders(npub, mapOf(
            "Content-Type" to "text/html", "Set-Cookie" to "a=1", "Link" to "<https://x.example>; rel=preconnect",
            "Strict-Transport-Security" to "max-age=1", "Content-Security-Policy" to "img-src 'self'", "X-Site" to "kept",
        ))
        assertEquals("kept", headers["X-Site"])
        for (gone in listOf("Set-Cookie", "Link", "Strict-Transport-Security", "Content-Type")) assertNull(gone, headers[gone])
        val csp = headers["Content-Security-Policy"]!!
        assertTrue("the site's own policy still holds", csp.startsWith("img-src 'self', "))
        assertTrue(csp.contains("default-src http://$npub.fips "))
        assertTrue("no websocket: WebView never intercepts one", csp.contains("connect-src http://$npub.fips;"))
        assertFalse("'self' would allow ws://<npub>.fips, which goes to DNS", FipsUrl.meshPolicy(npub).contains("'self'"))
        assertEquals("off", headers["X-DNS-Prefetch-Control"])
    }

    @Test fun typedAddressesGetAScheme() {
        assertEquals("http://$npub.fips/a", FipsUrl.typedUrl("$npub.fips/a"))
        assertEquals("https://example.com", FipsUrl.typedUrl("  example.com  "))
        assertEquals("https://example.com/x", FipsUrl.typedUrl("https://example.com/x"))
        assertEquals("http://$npub.fips/", FipsUrl.typedUrl("http://$npub.fips/"))
        assertNull(FipsUrl.typedUrl(""))
        assertNull(FipsUrl.typedUrl("two words"))
    }

    @Test fun pageTextIsEscaped() {
        assertEquals("&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;", FipsUrl.htmlEscaped("<a href=\"x\">'&'</a>"))
        assertEquals("plain", FipsUrl.htmlEscaped("plain"))
    }
}
