package com.nostrvault.ui.components

import com.nostrvault.data.model.QuoteRef
import com.nostrvault.relay.HavenBridge
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Each kind goes to its one site, named by an naddr or nprofile that decodes back. */
class NostrWebLinksTest {
    private val pubkey = "a723805cda67251191c8786f4da58f797e6977582301354ba8e91bcb0342dc9c"

    private fun naddrOf(url: String) = url.substringAfterLast('/')

    @Test fun `a recipe opens in zap cooking`() {
        val tags = listOf(listOf("d", "banana-bread"), listOf("t", "zapcooking"))
        val link = NostrWebLinks.forEvent(30023, pubkey, tags)!!
        assertEquals("Open in zap.cooking", link.label)
        assertEquals("https://zap.cooking/recipe/", link.url.substringBeforeLast('/') + "/")
        assertEquals(QuoteRef.Coordinate(30023, pubkey, "banana-bread"), HavenBridge.decodeNaddr(naddrOf(link.url)))
    }

    @Test fun `an article opens in YakiHonne`() {
        val link = NostrWebLinks.forEvent(30023, pubkey, listOf(listOf("d", "essay"), listOf("t", "bitcoin")))!!
        assertEquals("Open in YakiHonne", link.label)
        assertEquals("https://yakihonne.com/article/" + naddrOf(link.url), link.url)
        assertEquals(QuoteRef.Coordinate(30023, pubkey, "essay"), HavenBridge.decodeNaddr(naddrOf(link.url)))
    }

    @Test fun `a live stream opens in zap stream`() {
        val link = NostrWebLinks.forEvent(30311, pubkey, listOf(listOf("d", "show")))!!
        assertEquals("Open in zap.stream", link.label)
        assertEquals("https://zap.stream/" + naddrOf(link.url), link.url)
        assertEquals(QuoteRef.Coordinate(30311, pubkey, "show"), HavenBridge.decodeNaddr(naddrOf(link.url)))
    }

    @Test fun `a note or an address without a d tag gets no link`() {
        assertNull(NostrWebLinks.forEvent(1, pubkey, listOf(listOf("d", "x"))))
        assertNull(NostrWebLinks.forEvent(6, pubkey, listOf(listOf("e", "abc"))))
        assertNull(NostrWebLinks.forEvent(30023, pubkey, listOf(listOf("t", "zapcooking"))))
    }

    @Test fun `a person opens in Brainstorm by nprofile`() {
        val link = NostrWebLinks.forProfile(pubkey)!!
        assertEquals("Open in Brainstorm", link.label)
        val nprofile = link.url.removePrefix("https://brainstorm.world/p/")
        assertEquals(pubkey, HavenBridge.decodeNprofilePubkey(nprofile))
        assertNull(NostrWebLinks.forProfile("abcd"))
    }

    @Test fun `nprofile matches the NIP-19 example`() {
        assertEquals(
            "nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8gpp4mhxue69uhhytnc9e3k7mgpz4mhxue69uhkg6nzv9ejuumpv34kytnrdaksjlyr9p",
            HavenBridge.encodeNprofile(
                "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",
                listOf("wss://r.x.com", "wss://djbas.sadkb.com"),
            ),
        )
    }
}
