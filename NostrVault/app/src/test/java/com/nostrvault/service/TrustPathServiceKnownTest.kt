package com.nostrvault.service

import com.nostrvault.data.local.ConfigStore
import com.nostrvault.data.model.TrustPath
import com.nostrvault.relay.HavenConfig
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Right after a Follow the card reads "You follow them" without waiting on
 * relays (iOS testFollowIsKnownWithoutRelays). The relay client is a strict
 * mock: a relay query fails the test.
 */
class TrustPathServiceKnownTest {
    private val me = "me"
    private val author = "author"
    private val nostrService = mockk<NostrService>()
    private val configStore = mockk<ConfigStore> {
        every { activeAccountHexPubkey } returns MutableStateFlow(me)
        every { config } returns MutableStateFlow(HavenConfig())
    }
    private val trust = TrustPathService(nostrService, mockk(), configStore)

    @Test fun `someone you follow is a follow with no relay asked`() = runTest {
        val path = trust.path(author, me, listOf(author, "a"))
        assertEquals(TrustPath.Reach.FOLLOW, path.reach)
    }

    @Test fun `seen from someone else, their follow is known too`() = runTest {
        assertEquals(TrustPath.Reach.FOLLOW, trust.path(author, "them", listOf(author)).reach)
    }
}
