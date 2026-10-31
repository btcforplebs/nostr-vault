package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Test

/** Delete token tags, same as iOS BlossomDeleteAuth (Tron on PR 1403). */
class BlossomDeleteAuthTest {
    private val sha = "c".repeat(64)

    @Test fun `a mirror token names its server and the delete url and lasts five minutes`() {
        assertEquals(
            listOf(
                listOf("t", "delete"),
                listOf("x", sha),
                listOf("u", "https://Blossom.Primal.net/$sha"),
                listOf("server", "blossom.primal.net"),
                listOf("expiration", "1700000300"),
            ),
            BlossomDeleteAuth.tags(sha, "https://Blossom.Primal.net/$sha", nowSeconds = 1_700_000_000),
        )
    }

    @Test fun `extra servers are named once, with no url when none is given`() {
        assertEquals(
            listOf(
                listOf("t", "delete"), listOf("t", "get"),
                listOf("x", sha),
                listOf("server", "npub1a.fips"), listOf("server", "npub1b.fips"),
                listOf("expiration", "1700000300"),
            ),
            BlossomDeleteAuth.tags(
                sha, "", nowSeconds = 1_700_000_000, operations = listOf("delete", "get"),
                servers = listOf("npub1a.fips", "NPUB1B.fips", "npub1a.fips"),
            ),
        )
    }
}
