package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A user's lists are never overwritten by accident (Logen 2026-10-31): kind 0, 3, 10000, 10002, 10006, 10015,
 * 10050 and 10063 are signed only from the places listed here. Any new place that signs one of them, or any new
 * signing wrapper that takes its kind from a variable, fails this test until someone reviews it and adds it.
 * Paths from Tron's audit at 633d5552 (RESEARCH/NV_LIST_OVERWRITE_AUDIT_633D5552.md). Model:
 * [ServerListPublishOnlyOnSaveTest] (10063 only from Save in Media servers).
 *
 * The last tests pin the fixes for the live paths the audit found (Logen 2026-10-31: never sign a list
 * automatically, fetch the newest copy right before Save and edit that, one "none" is not "you have none").
 */
class UserListSignGuardTest {

    private val root = File("src/main/java")

    /** Each Kotlin file's text with all whitespace collapsed, so a call split over lines reads as one. */
    private val sources: Map<String, String> = root.walkTopDown()
        .filter { it.isFile && it.extension == "kt" }
        .associate { it.relativeTo(root).path to it.readText().replace(Regex("\\s+"), " ") }

    private val listKinds = setOf(0, 3, 10000, 10002, 10006, 10015, 10050, 10063)

    /** Named kinds that are list kinds. */
    private val namedListKinds = mapOf("InterestList.KIND" to InterestList.KIND)

    /** A sign call and its kind argument (not a declaration). */
    private val signCall = Regex(
        "(?<!fun )\\b(signEventAsync|signAndPost|signEvent|publishOwnerEntryList)\\s*\\(\\s*(?:kind\\s*=\\s*)?([A-Za-z0-9_.]+)",
    )

    private fun scan(): Pair<Map<String, Set<Int>>, Map<String, Set<String>>> {
        val lists = sortedMapOf<String, MutableSet<Int>>()
        val generic = sortedMapOf<String, MutableSet<String>>()
        for ((path, text) in sources) for (m in signCall.findAll(text)) {
            val arg = m.groupValues[2]
            val kind = arg.toIntOrNull() ?: namedListKinds[arg]
            when {
                kind != null && kind in listKinds -> lists.getOrPut(path) { sortedSetOf() } += kind
                kind == null -> generic.getOrPut(path) { sortedSetOf() } += arg
            }
        }
        return lists to generic
    }

    @Test
    fun `the pattern catches every way a list is signed`() {
        // Positive control: a multi-line call (as in FeedServiceFollow), named and positional kinds.
        val samples = listOf(
            "nostrService.signEventAsync( kind = 3, content = content,",
            "signAndPost(kind = 10002, content = \"\"",
            "publishOwnerEntryList(10063, \"server\"",
            "nostrService.signEventAsync( kind = InterestList.KIND,",
        )
        samples.forEach { assertTrue(it, signCall.containsMatchIn(it.replace(Regex("\\s+"), " "))) }
        assertFalse("a declaration is not a call", signCall.containsMatchIn("fun signEventAsync(kind: Int"))
        assertEquals(10015, InterestList.KIND)
    }

    @Test
    fun `only these places sign a user list`() {
        assertEquals(
            mapOf(
                // Follow / unfollow taps, follow-many and Restore, through publishContactList.
                "com/nostrvault/service/FeedServiceFollow.kt" to setOf(3),
                // Interests: the hashtag follow tap.
                "com/nostrvault/service/InterestListService.kt" to setOf(10015),
                // 10000 Block, 10002/10050 Save in Relays, 10006 + 10063 Save in Media servers / relay sets.
                "com/nostrvault/service/nostr/NostrServiceListPublishing.kt" to setOf(10000, 10002, 10006, 10050, 10063),
                // Save in Edit profile.
                "com/nostrvault/ui/screens/profile/ProfileEditSheet.kt" to setOf(0),
                // A new account finishing setup (no list exists yet).
                "com/nostrvault/ui/screens/setupwizard/SetupWizardViewModelCompletion.kt" to setOf(0, 10002),
            ),
            scan().first,
        )
    }

    @Test
    fun `no new signer takes its kind from a variable`() {
        // Each of these signs a kind it is handed. A new one could sign a list; review it, then add it here.
        assertEquals(
            mapOf(
                "com/nostrvault/service/DraftService.kt" to setOf("DraftEvents.KIND"),
                "com/nostrvault/service/EventPublisher.kt" to setOf("eventJSON"),
                "com/nostrvault/service/FeedServiceReactions.kt" to setOf("repostKind"),
                "com/nostrvault/service/LiveChatService.kt" to setOf("CHAT_KIND"),
                "com/nostrvault/service/MediaPostQueue.kt" to setOf("kind"),
                "com/nostrvault/service/NIP17Service.kt" to setOf("sealEventJson"),
                "com/nostrvault/service/NostrService.kt" to setOf("kind"),
                "com/nostrvault/service/NwcBackupService.kt" to setOf("NwcBackup.KIND"),
                "com/nostrvault/service/PollStore.kt" to setOf("NIP88Poll.RESPONSE_KIND"),
                "com/nostrvault/service/blossom/BlossomServiceMirroring.kt" to setOf("AUTH_KIND"),
                "com/nostrvault/service/blossom/BlossomServiceUploadAuth.kt" to setOf("AUTH_KIND"),
                "com/nostrvault/service/dm/DMServiceCrypto.kt" to setOf("sealEventJson"),
                "com/nostrvault/service/nostr/NostrServiceDeletedPosts.kt" to setOf("draft.kind"),
                "com/nostrvault/service/nostr/NostrServiceListPublishing.kt" to setOf("kind"),
                "com/nostrvault/service/nostr/NostrServiceSigning.kt" to setOf("eventJson", "kind", "lockedTo"),
                "com/nostrvault/ui/screens/articles/ArticleReaderViewModel.kt" to setOf("ArticleEngagement.HIGHLIGHT_KIND"),
                "com/nostrvault/ui/screens/compose/ComposeNoteViewModel.kt" to setOf("eventKind"),
                "com/nostrvault/ui/screens/compose/ModeComposeViewModel.kt" to setOf(
                    "DivinePost.KIND", "LongFormDraft.KIND",
                    "com.nostrvault.data.model.ListingDraft.KIND", "com.nostrvault.data.model.NIP88Poll.KIND",
                ),
            ),
            scan().second,
        )
    }

    private fun src(path: String) = sources.getValue(path)

    // MARK: the live paths Tron's audit at 633d5552 found, now closed.

    @Test
    fun `loading the follow list never re-signs it`() {
        assertFalse(src("com/nostrvault/service/FeedServiceContactList.kt").contains("publishContactList("))
    }

    @Test
    fun `a follow tap reads the newest kind 3 before signing`() {
        val follow = src("com/nostrvault/service/FeedServiceFollow.kt")
        assertTrue(Regex("(lookup|fetch)NewestReplaceable\\(\\s*(kind\\s*=\\s*)?3\\b").containsMatchIn(follow))
    }

    @Test
    fun `one relay saying none is not enough to publish a 10063 or 10006`() {
        assertFalse(src("com/nostrvault/service/nostr/NostrServiceListPublishing.kt").contains("lookup.event == null && lookup.answered == 0"))
    }

    @Test
    fun `one relay answering is not enough to publish a 10015`() {
        assertFalse(src("com/nostrvault/service/InterestListService.kt").contains("answered.get() > 0"))
    }

    @Test
    fun `Save in Relays reads the newest 10002 at Save`() {
        val impl = src("com/nostrvault/service/nostr/NostrServiceListPublishing.kt")
            .substringAfter("fun NostrService.publishOwnerRelayListTagsImpl").substringBefore(" fun ")
        assertTrue(impl.contains("lookupNewestReplaceable"))
    }

    @Test
    fun `Save in Relays refuses when the list it opened with is missing or older at Save`() {
        val file = src("com/nostrvault/service/nostr/NostrServiceListPublishing.kt")
        for ((fn, rebase) in listOf(
            "fun NostrService.publishOwnerRelayListTagsImpl" to "rebaseRelayList",
            "fun NostrService.publishDMRelayList" to "rebaseDMList",
        )) {
            val impl = file.substringAfter(fn).substringBefore(" fun ")
            val guard = impl.indexOf("staleAtSave(")
            assertTrue("$fn must check staleAtSave", guard >= 0)
            assertTrue("$fn must check staleAtSave before $rebase", guard < impl.indexOf(rebase))
            assertTrue("$fn must pass the found copy's created_at", impl.contains("lookup.event?.createdAt"))
        }
    }
}
