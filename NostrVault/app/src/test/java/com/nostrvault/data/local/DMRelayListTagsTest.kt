package com.nostrvault.data.local

import org.junit.Assert.assertEquals
import org.junit.Test

/** Kind 10050 relay tags: NIP-17's ["relay", url], plus older Nostr Vault's ["r", url]. */
class DMRelayListTagsTest {
    @Test
    fun readsNip17RelayTags() {
        val tags = listOf(listOf("relay", "wss://inbox.nostr.wine"), listOf("relay", "wss://auth.nostr1.com"))
        assertEquals(listOf("wss://inbox.nostr.wine", "wss://auth.nostr1.com"), ProfileRepository.parseDMRelayListTags(tags))
    }

    @Test
    fun stillReadsLegacyRTagsAndDropsDuplicates() {
        val tags = listOf(listOf("r", "wss://relay.damus.io"), listOf("relay", "wss://relay.damus.io"), listOf("relay", "not a url"))
        assertEquals(listOf("wss://relay.damus.io"), ProfileRepository.parseDMRelayListTags(tags))
    }
}
