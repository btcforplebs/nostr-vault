package com.nostrvault.ui.navigation

import com.nostrvault.data.model.VaultViewMode
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

    private val hexPost = "c".repeat(64)

    private fun eventJson(id: String, kind: Int, tags: String = "[]", content: String = "gm") =
        """{"id":"$id","pubkey":"$hexAuthor","created_at":1800000000,"kind":$kind,"tags":$tags,"content":"$content","sig":"00"}"""

    @Test fun `a mention notification opens its post from the copy it carries`() {
        val target = DeepLinkRouter.fromNotification(
            "mention", hexNote, hexAuthor, "npub1abc", event = eventJson(hexNote, 1, content = "hello"),
        )
        assertEquals(Screen.NoteDetail.createRoute(hexNote), target?.route)
        assertEquals("hello", target?.seedNote?.content)
        assertNull(target?.relayFocus)
        assertEquals("npub1abc", target?.accountNpub)
    }

    @Test fun `a mention without a carried copy still opens its post, by id`() {
        for (type in listOf("mention", "reply", "quote")) {
            val target = DeepLinkRouter.fromNotification(type, hexNote, hexAuthor, null)
            assertEquals(type, Screen.NoteDetail.createRoute(hexNote), target?.route)
            assertNull(type, target?.seedNote)
            assertNull(type, target?.relayFocus)
        }
    }

    @Test fun `a like or zap opens the post it is about, not itself`() {
        val like = eventJson(hexNote, 7, tags = """[["e","$hexPost"],["p","$hexAuthor"]]""", content = "+")
        val post = eventJson(hexPost, 1, content = "my post")
        for (type in listOf("reaction", "zap", "repost")) {
            val carried = DeepLinkRouter.fromNotification(type, hexNote, hexAuthor, null, event = like, target = post)
            assertEquals(type, Screen.NoteDetail.createRoute(hexPost), carried?.route)
            assertEquals(type, "my post", carried?.seedNote?.content)
            // The post was not in the notification: open it by the like's e tag.
            val byId = DeepLinkRouter.fromNotification(type, hexNote, hexAuthor, null, event = like)
            assertEquals(type, Screen.NoteDetail.createRoute(hexPost), byId?.route)
            assertNull(type, byId?.seedNote)
        }
    }

    @Test fun `with no post to open, a like or zap falls back to the Relay tab`() {
        // A zap on a profile has no e tag; an alert with no copy only names the like.
        val profileZap = eventJson(hexNote, 9735, tags = """[["p","$hexAuthor"]]""")
        val zap = DeepLinkRouter.fromNotification("zap", hexNote, hexAuthor, null, event = profileZap)
        assertEquals(Screen.Dashboard.route, zap?.route)
        assertEquals(RelayFocusRequest("zap", hexNote), zap?.relayFocus)
        val like = DeepLinkRouter.fromNotification("reaction", hexNote, hexAuthor, null)
        assertEquals(RelayFocusRequest("reaction", hexNote), like?.relayFocus)
    }

    @Test fun `a carried copy that is not a whole event is ignored`() {
        val target = DeepLinkRouter.fromNotification("mention", hexNote, hexAuthor, null, event = """{"id":"$hexNote"}""")
        assertEquals(Screen.NoteDetail.createRoute(hexNote), target?.route)
        assertNull(target?.seedNote)
        assertNull(NotificationNote.decode("not json"))
        assertNull(NotificationNote.decode(eventJson("abc", 1)))
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

    @Test fun `a new follower notification opens the follower's profile`() {
        val target = DeepLinkRouter.fromNotification("follow", hexNote, hexAuthor, "npub1abc")
        assertEquals(Screen.Profile.createRoute(hexAuthor), target?.route)
        assertEquals("npub1abc", target?.accountNpub)
        assertNull(target?.relayFocus)
    }

    @Test fun `the folded new-followers alert opens the Followers list`() {
        val target = DeepLinkRouter.fromNotification("followers", "followers-npub1abc", "", "npub1abc")
        assertEquals(Screen.Dashboard.route, target?.route)
        assertEquals("npub1abc", target?.accountNpub)
        assertEquals(RelayFocusRequest(type = "followers", eventId = ""), target?.relayFocus)
        assertEquals(VaultViewMode.FOLLOWERS, NotificationTarget.viewFor("followers", zapsOnly = false))
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
