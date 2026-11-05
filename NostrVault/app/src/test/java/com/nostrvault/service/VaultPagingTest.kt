package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Paging past the vault's 1,000 cap, which replaced a re-ask (and a login) per list kind (#1739 twin). */
class VaultPagingTest {
    private fun page(n: Int, from: Long, prefix: String = "e") = (0 until n).map { "$prefix$it" to (from - it) }

    @Test
    fun `under the limit is the last page`() {
        assertNull(VaultPaging.nextUntil(page(999, 5_000), emptySet()))
    }

    @Test
    fun `a full page asks until its oldest`() {
        assertEquals(4_001L, VaultPaging.nextUntil(page(1000, 5_000), emptySet()))
    }

    @Test
    fun `a full page with nothing new steps one second back`() {
        val p = page(1000, 5_000)
        assertEquals(4_000L, VaultPaging.nextUntil(p, p.map { it.first }.toSet()))
    }
}
