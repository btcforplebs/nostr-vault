package com.nostrvault.ui.navigation

import com.nostrvault.data.model.AccountUnread
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.relay.HavenBridge
import com.nostrvault.relay.HavenConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * The nav host reads [navBarAccounts] through a derivedStateOf, so it and the
 * bottom bar only redraw when this value changes. A profile write for someone
 * outside the roster (an alert's author, a feed row's) must leave it equal;
 * one for an account in the roster must not.
 */
class NavBarAccountsTest {
    private val ownerHex = "1".repeat(64)
    private val otherHex = "2".repeat(64)
    private val strangerHex = "3".repeat(64)
    private val config = HavenConfig(
        ownerNpub = HavenBridge.encodeNpub(ownerHex)!!,
        accountNpubs = listOf(HavenBridge.encodeNpub(otherHex)!!),
    )
    private val base = mapOf(
        ownerHex to FeedProfile(pubkey = ownerHex, name = "Owner", pictureURL = "https://pic/owner.jpg"),
        otherHex to FeedProfile(pubkey = otherHex, name = "Other"),
    )

    private fun of(profiles: Map<String, FeedProfile>, unread: AccountUnread = AccountUnread()) =
        navBarAccounts(config, profiles, unread, ownerHex)

    @Test fun `the bar shows the active account's picture and name`() {
        val v = of(base)
        assertEquals("https://pic/owner.jpg", v.avatarUrl)
        assertEquals("Owner", v.displayName)
        assertEquals(listOf("Owner", "Other"), v.accounts.map { it.displayName })
    }

    @Test fun `a stranger's profile arriving changes nothing the host reads`() {
        val before = of(base)
        val after = of(base + (strangerHex to FeedProfile(pubkey = strangerHex, name = "Alert author")))
        assertEquals(before, after)
    }

    @Test fun `a new picture for the active account does change it`() {
        val renamed = base + (ownerHex to FeedProfile(pubkey = ownerHex, name = "Owner", pictureURL = "https://pic/new.jpg"))
        assertNotEquals(of(base), of(renamed))
        assertEquals("https://pic/new.jpg", of(renamed).avatarUrl)
    }

    @Test fun `another account's name or unread count changes the roster`() {
        val renamed = base + (otherHex to FeedProfile(pubkey = otherHex, name = "Renamed"))
        assertNotEquals(of(base), of(renamed))
        assertNotEquals(of(base), of(base, AccountUnread(mapOf(otherHex to listOf("e1")))))
    }
}
