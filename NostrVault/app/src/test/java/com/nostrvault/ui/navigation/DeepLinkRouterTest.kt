package com.nostrvault.ui.navigation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The router is the one place that maps outside taps to screens, so these
 * pin the mapping itself — including the cases where the honest answer is
 * "no destination", which is what keeps a bad link from dumping the user
 * somewhere arbitrary.
 */
class DeepLinkRouterTest {

    private val hexNote = "a".repeat(64)
    private val hexAuthor = "b".repeat(64)

    /** Decodes exactly one entity of each kind, so a test that passes proves the
     *  router asked the decoder rather than passing bech32 through as hex. */
    private val decoder = object : NostrEntityDecoder {
        override fun noteToHex(note1: String) = if (note1 == "note1good") hexNote else null
        override fun neventToHex(nevent1: String) = if (nevent1 == "nevent1good") hexNote else null
        override fun npubToHex(npub: String) = if (npub == "npub1good") hexAuthor else null
        override fun nprofileToHex(nprofile: String) = if (nprofile == "nprofile1good") hexAuthor else null
    }

    private fun route(uri: String) = DeepLinkRouter.fromUri(uri, decoder)?.route

    @Test fun `app link destinations map to screens`() {
        assertEquals(Screen.Feed.route, route("nostrvault://feed"))
        assertEquals(Screen.DMInbox.route, route("nostrvault://dms"))
        assertEquals(Screen.Search.route, route("nostrvault://search"))
        assertEquals(Screen.Dashboard.route, route("nostrvault://relay"))
        assertEquals(Screen.MediaGallery.route, route("nostrvault://media"))
        assertEquals(Screen.Wallet.route, route("nostrvault://wallet"))
        assertEquals(Screen.ComposeNote.createRoute(), route("nostrvault://compose"))
    }

    @Test fun `mediapaste opens the Media tab with a paste request`() {
        val target = DeepLinkRouter.fromUri("nostrvault://mediapaste", decoder)!!
        assertEquals(Screen.MediaGallery.route, target.route)
        assertEquals(true, target.mediaPaste)
        assertEquals(false, DeepLinkRouter.fromUri("nostrvault://media", decoder)!!.mediaPaste)
    }

    @Test fun `clipboard paste prefers media, then a link`() {
        assertEquals(ClipboardMedia.ContentUri("content://x/1"), ClipboardMedia.from("content://x/1", "https://a.example/b.jpg"))
        assertEquals(ClipboardMedia.Link("https://a.example/b.jpg"), ClipboardMedia.from(null, "  https://a.example/b.jpg \n"))
        assertEquals(ClipboardMedia.NotALink, ClipboardMedia.from(null, "hello there"))
        assertEquals(ClipboardMedia.NotALink, ClipboardMedia.from(null, "ftp://a.example/b"))
        assertEquals(ClipboardMedia.Empty, ClipboardMedia.from(null, "  "))
        assertEquals(ClipboardMedia.Empty, ClipboardMedia.from(null, null))
    }

    @Test fun `bare scheme and trailing slash open the feed`() {
        assertEquals(Screen.Feed.route, route("nostrvault://"))
        assertEquals(Screen.Feed.route, route("nostrvault://feed/"))
    }

    @Test fun `unknown destination yields nothing rather than a guess`() {
        assertNull(route("nostrvault://sparkles"))
        assertNull(route("https://example.com/note1good"))
    }

    @Test fun `nostr entities open the note or the profile`() {
        assertEquals(Screen.NoteDetail.createRoute(hexNote), route("nostr:note1good"))
        assertEquals(Screen.NoteDetail.createRoute(hexNote), route("nostr:nevent1good"))
        assertEquals(Screen.Profile.createRoute(hexAuthor), route("nostr:npub1good"))
        assertEquals(Screen.Profile.createRoute(hexAuthor), route("nostr:nprofile1good"))
        // Bare, as another app might share it
        assertEquals(Screen.NoteDetail.createRoute(hexNote), route("note1good"))
    }

    @Test fun `an entity the decoder rejects is not routed`() {
        assertNull(route("nostr:note1typo"))
        assertNull(route("nostr:npub1typo"))
    }

    @Test fun `naddr has no screen yet and must not fall through to the feed`() {
        assertNull(route("nostr:naddr1qqxnzd3exyc"))
    }

    @Test fun `hex ids are accepted directly`() {
        assertEquals(Screen.NoteDetail.createRoute(hexNote), route("nostrvault://note/$hexNote"))
        assertEquals(Screen.Profile.createRoute(hexAuthor), route("nostrvault://profile/$hexAuthor"))
        // 63 characters is not an event id.
        assertNull(route("nostrvault://note/" + "a".repeat(63)))
    }

    @Test fun `a reaction notification without its post lands in the Relay tab`() {
        val target = DeepLinkRouter.fromNotification("reaction", hexNote, hexAuthor, "npub1abc")
        assertEquals(Screen.Dashboard.route, target?.route)
        assertEquals(RelayFocusRequest("reaction", hexNote), target?.relayFocus)
        assertEquals("npub1abc", target?.accountNpub)
    }

    @Test fun `a reaction, repost or zap without a looked-up post focuses the Relay tab`() {
        // "reaction" used to route nowhere, so a like tap did nothing.
        for (type in listOf("reaction", "repost", "zap")) {
            val target = DeepLinkRouter.fromNotification(type, hexNote, hexAuthor, null)
            assertEquals(type, Screen.Dashboard.route, target?.route)
            assertEquals(type, RelayFocusRequest(type, hexNote), target?.relayFocus)
        }
    }

    @Test fun `a post notification with its post opens that post`() {
        for (type in listOf("mention", "reply", "quote", "reaction", "repost", "zap")) {
            val target = DeepLinkRouter.fromNotification(type, hexNote, hexAuthor, "npub1abc", noteId = hexAuthor)
            assertEquals(type, Screen.NoteDetail.createRoute(hexAuthor), target?.route)
            assertNull(type, target?.relayFocus)
            assertEquals(type, "npub1abc", target?.accountNpub)
        }
    }

    @Test fun `a mention or reply without a looked-up post opens itself`() {
        for (type in listOf("mention", "reply", "quote")) {
            val target = DeepLinkRouter.fromNotification(type, hexNote, hexAuthor, null)
            assertEquals(type, Screen.NoteDetail.createRoute(hexNote), target?.route)
        }
    }

    @Test fun `a DM notification opens the conversation, not the gift wrap`() {
        val target = DeepLinkRouter.fromNotification("dm", hexNote, hexAuthor, null)
        assertEquals(Screen.DMThread.createRoute(hexAuthor), target?.route)
        assertNull(target?.accountNpub)
        assertNull(target?.relayFocus)
    }

    @Test fun `a gift wrap notification opens the inbox, not a thread with the wrap key`() {
        // The marker's author is the one-time wrapping key, not the sender.
        val target = DeepLinkRouter.fromNotification("giftwrap", hexNote, hexAuthor, null)
        assertEquals(Screen.DMInbox.route, target?.route)
    }

    @Test fun `the catch-up summary carries no event id and opens the feed`() {
        assertEquals(Screen.Feed.route, DeepLinkRouter.fromNotification("summary", "", "", "")?.route)
    }

    @Test fun `a notification missing its ids routes nowhere`() {
        assertNull(DeepLinkRouter.fromNotification("mention", null, hexAuthor, null))
        assertNull(DeepLinkRouter.fromNotification("dm", hexNote, "", null))
        assertNull(DeepLinkRouter.fromNotification(null, hexNote, hexAuthor, null))
    }
}
