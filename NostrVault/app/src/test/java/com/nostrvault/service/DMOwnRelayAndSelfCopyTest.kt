package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Two DM breakages pinned at the source (the gift-wrap crypto needs the Go
 * bridge, which plain unit tests can't load):
 *
 * 1. The /chat AUTH must be signed with the vault's ServiceURL (wss://, see
 *    VaultAuthTagTest), not the ws:// socket address, or the owner AUTH fails
 *    and DM history held in the phone's own relay never loads.
 * 2. Your own copy of a sent DM is sealed TO you but keeps the recipient in the
 *    rumor's `p` tag (iOS createGiftWrap rumorPTags/giftWrapRecipient). Built as
 *    a DM to yourself, every sent message was filed as a chat with yourself.
 */
class DMOwnRelayAndSelfCopyTest {
    private fun src(path: String) = File("src/main/java/com/nostrvault/$path").readText()

    @Test
    fun `chat AUTH is signed with the vault auth tag`() {
        val fn = src("service/dm/DMServiceListening.kt").substringAfter("fun DMService.handleAuthChallenge")
        val tagLine = fn.lines().first { "val relayUrl" in it }
        assertTrue(tagLine, "vaultAuthRelayTag(" in tagLine)
    }

    @Test
    fun `own copy keeps the recipient as the conversation`() {
        val send = src("service/dm/DMServiceSending.kt").substringAfter("fun DMService.sendNIP17DM").substringBefore("fun DMService.sendNIP04DM")
        assertFalse("self copy built as a DM to yourself", "recipientPubkey = ownHexPubkey" in send)
        assertEquals(3, Regex("giftWrapRecipient = ownHexPubkey").findAll(send).count())
    }

    @Test
    fun `rumor p is the recipient while seal and wrap go to giftWrapRecipient`() {
        for (path in listOf("service/NIP17Service.kt", "service/dm/DMServiceCrypto.kt")) {
            val s = src(path)
            for (builder in listOf("fun createGiftWrappedDM(", "fun createGiftWrappedDMWithAmber(", "fun DMService.createGiftWrappedDMWithBunker(")) {
                if (builder !in s) continue
                val body = s.substringAfter(builder).substringBefore("\n    }\n").substringBefore("\n}\n")
                // The rumor (kind 14 or a kind 15 file message) is built by DMRumor, p = recipientPubkey.
                val call = "rumor.build(senderPubkey, recipientPubkey, content)"
                assertTrue("$builder rumor p", call in body)
                val afterRumor = body.substringAfter(call)
                assertFalse("$builder seals or wraps to recipientPubkey", Regex("""[(,]\s*recipientPubkey[,)]""").containsMatchIn(afterRumor))
                assertTrue("$builder uses giftWrapRecipient", "giftWrapRecipient" in afterRumor)
            }
        }
        assertTrue("DMRumor p", "listOf(listOf(\"p\", recipientPubkey)) + fileTags" in src("service/dm/DMRumor.kt"))
    }
}
