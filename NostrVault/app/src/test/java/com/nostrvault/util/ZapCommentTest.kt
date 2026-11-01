package com.nostrvault.util

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** A zap carries only what the user wrote (Logen, 11-01): no app-supplied text. Twin of ZapCommentTests.swift. */
class ZapCommentTest {
    @Test fun nothingTypedSendsNothing() {
        assertEquals("", ZapComment.content(""))
        assertEquals("", ZapComment.content("   \n\t "))
    }

    @Test fun typedCommentIsTrimmed() {
        assertEquals("great set!", ZapComment.content("  great set!\n"))
    }

    @Test fun longCommentIsCapped() {
        val long = "a".repeat(ZapComment.MAX_LENGTH + 50)
        assertEquals(ZapComment.MAX_LENGTH, ZapComment.content(long).length)
    }

    /** No zap path signs app text: the old "Zap from Nostr Vault" went out on every one-tap zap. */
    @Test fun noAppDefaultZapComment() {
        val main = File("src/main/java/com/nostrvault")
        assertTrue("run from NostrVault/app", main.isDirectory)
        val service = File(main, "service/ZapSendService.kt").readText()
        assertTrue(service.contains("message: String = \"\""))
        val hits = main.walk().filter { it.extension == "kt" }
            .filter { it.readText().contains("Zap from Nostr Vault") }.map { it.name }.toList()
        assertEquals(emptyList<String>(), hits)
        // Logen keeps the paid-article line.
        assertTrue(File(main, "service/GatedArticleService.kt").readText().contains("Unlocked with Nostr Vault"))
        assertFalse(service.contains("Nostr Vault\","))
    }
}
