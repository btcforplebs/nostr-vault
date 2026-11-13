package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.ZoneOffset

/**
 * Strangers' likes and reposts fold out of the Vault list's All into one
 * "N from outside your web" line (Logen 2026-11-13, option A). Mirrors iOS
 * WotStricterTests.
 */
class VaultOutsideFoldTest {
    private val me = "a".repeat(64)
    private val friend = "b".repeat(64)
    private val stranger = "c".repeat(64)
    private val stranger2 = "d".repeat(64)
    private val noteKinds = setOf(1, 6, 30023, 1111, 9802, 1068)

    private fun event(id: String, pubkey: String, kind: Int = 1, at: Long, content: String = "", tags: List<List<String>> = emptyList()) =
        VaultActivity.Event(id, pubkey, kind, at, content, tags)

    private val events = listOf(
        event("post", me, at = 100, content = "my post"),
        event("l1", friend, kind = 7, at = 110, content = "+", tags = listOf(listOf("e", "post"), listOf("p", me))),
        event("l2", stranger, kind = 7, at = 120, content = "+", tags = listOf(listOf("e", "post"), listOf("p", me))),
        event("l3", stranger2, kind = 7, at = 125, content = "+", tags = listOf(listOf("e", "post"), listOf("p", me))),
        event("rp", stranger, kind = 6, at = 130, tags = listOf(listOf("e", "post"), listOf("p", me))),
        event("reply", stranger, at = 140, content = "spam", tags = listOf(listOf("e", "post"), listOf("p", me))),
    )
    private val outside: (String) -> Boolean = { it == stranger || it == stranger2 }

    private fun build(outsideOnly: Boolean = false, folds: Boolean = true) = VaultActivity.build(
        events, me, noteKinds, isOutside = outside, zone = ZoneOffset.UTC, outsideOnly = outsideOnly, foldsOutsideLikes = folds,
    )

    @Test fun `all keeps a friend's like and drops strangers' likes and reposts`() {
        val lines = build()
        assertEquals(listOf(VaultActivity.Kind.REACTION), lines.map { it.kind })
        assertEquals(listOf(friend), lines[0].actors)
    }

    @Test fun `outside your web lists strangers' likes, reposts and posts`() {
        val lines = build(outsideOnly = true)
        assertEquals(setOf(VaultActivity.Kind.REACTION, VaultActivity.Kind.REPOST, VaultActivity.Kind.REPLY), lines.map { it.kind }.toSet())
        assertEquals(listOf(stranger2, stranger), lines.first { it.kind == VaultActivity.Kind.REACTION }.actors)
    }

    @Test fun `the fold line counts each stranger once per line`() {
        val outsideLines = build(outsideOnly = true)
        assertEquals(3, VaultOutsideFold.count(outsideLines))
        assertEquals(1, VaultOutsideFold.count(outsideLines, zapsOnly = true))
        assertEquals("3 from outside your web", VaultOutsideFold.label(3))
    }

    @Test fun `zaps from strangers keep their line`() {
        val zap = event(
            "zap-1", "f".repeat(64), kind = 9735, at = 150,
            tags = listOf(
                listOf("p", me), listOf("e", "post"), listOf("bolt11", "lnbc10n1"),
                listOf("description", """{"pubkey":"$stranger","content":"","kind":9734,"tags":[["p","$me"],["e","post"],["amount","1000"]]}"""),
            ),
        )
        val lines = VaultActivity.build(events + zap, me, noteKinds, isOutside = outside, zone = ZoneOffset.UTC, foldsOutsideLikes = true)
        assertEquals(true, lines.any { it.kind == VaultActivity.Kind.ZAP })
    }

    @Test fun `without the fold strangers' likes stay, as before`() {
        assertEquals(setOf(friend, stranger, stranger2), build(folds = false).first { it.kind == VaultActivity.Kind.REACTION }.actors.toSet())
    }
}
