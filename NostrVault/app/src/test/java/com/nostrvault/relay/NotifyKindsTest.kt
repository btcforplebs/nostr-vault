package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * NOTIFY_KINDS is how the relay is told which kinds may raise a notification.
 * Android never sent it, and haven-go reads an absent/empty value as "notify
 * for everything" — so the catch-up summary ("N more new items while you were
 * away") counted kinds the user had switched off. Mirrors iOS
 * RelayConfiguration.notifyKinds / NotificationPolicy.notifyKinds.
 */
class NotifyKindsTest {

    private val owner = "npub1owner"
    private val second = "npub1second"

    private fun config(
        push: Boolean = true,
        prefs: Map<String, PushPrefs> = emptyMap(),
        accounts: List<String> = emptyList(),
        zapsOnly: Boolean = false,
    ) = HavenConfig(
        ownerNpub = owner,
        accountNpubs = accounts,
        enablePushNotifications = push,
        pushPrefsPerAccount = prefs,
        zapsOnlyMode = zapsOnly,
    )

    @Test
    fun `an account with no stored prefs counts as the defaults`() {
        // Someone who never opened notification settings has no entry at all;
        // leaving them out would tell the relay to notify for nothing.
        val kinds = RelayConfiguration.notifyKinds(config())
        assertEquals(listOf(1, 4, 1059, 1111, 9735), kinds)
    }

    @Test
    fun `switched-off kinds are left out`() {
        val prefs = PushPrefs(mentions = false, replies = false, dms = true, zaps = false)
        assertEquals(listOf(4, 1059), RelayConfiguration.notifyKinds(config(prefs = mapOf(owner to prefs))))
    }

    @Test
    fun `nothing enabled asks for the silent kind, never an empty list`() {
        // An empty NOTIFY_KINDS means "no preference" to the relay, i.e. notify
        // for everything — the opposite of what the user asked for.
        val off = PushPrefs(mentions = false, replies = false, dms = false, zaps = false)
        val kinds = RelayConfiguration.notifyKinds(config(prefs = mapOf(owner to off)))
        assertEquals(listOf(RelayConfiguration.SILENT_NOTIFY_KIND), kinds)
        assertTrue(kinds.isNotEmpty())
    }

    @Test
    fun `the relay is shared, so the set is the union across accounts`() {
        val quiet = PushPrefs(mentions = false, replies = false, dms = false, zaps = false)
        val loud = PushPrefs(mentions = false, replies = false, dms = false, zaps = false, reactions = true)
        val kinds = RelayConfiguration.notifyKinds(
            config(prefs = mapOf(owner to quiet, second to loud), accounts = listOf(second)),
        )
        assertEquals(listOf(7), kinds)
    }

    @Test
    fun `with push off only DMs stay marked, for the in-app banner`() {
        val kinds = RelayConfiguration.notifyKinds(config(push = false))
        assertEquals(listOf(4, 1059), kinds)
    }

    @Test
    fun `zaps-only mode drops reactions even when the toggle is on`() {
        val prefs = PushPrefs(mentions = false, replies = false, dms = false, zaps = false, reactions = true)
        val kinds = RelayConfiguration.notifyKinds(
            config(prefs = mapOf(owner to prefs), zapsOnly = true),
        )
        assertEquals(listOf(RelayConfiguration.SILENT_NOTIFY_KIND), kinds)
    }

    @Test
    fun `a reply toggle also enables NIP-22 comments`() {
        val prefs = PushPrefs(mentions = false, replies = true, dms = false, zaps = false)
        assertEquals(listOf(1, 1111), RelayConfiguration.notifyKinds(config(prefs = mapOf(owner to prefs))))
    }

    @Test
    fun `reposts cover the generic repost kind`() {
        val prefs = PushPrefs(mentions = false, replies = false, dms = false, zaps = false, reposts = true)
        assertEquals(listOf(6, 16), RelayConfiguration.notifyKinds(config(prefs = mapOf(owner to prefs))))
    }

    @Test
    fun `the env carries the kinds as a comma-separated list`() {
        val env = RelayConfiguration.generateEnvDictionary(
            config(),
            java.io.File(System.getProperty("java.io.tmpdir"), "notify-kinds-test"),
        )
        assertEquals("1,4,1059,1111,9735", env["NOTIFY_KINDS"])
    }

    @Test
    fun `the global follows flag reaches an account with no stored prefs`() {
        // pushPrefsFor's fallback left `follows` out, so it always read as the
        // PushPrefs default true and the global switch could not turn it off.
        val off = HavenConfig(ownerNpub = owner, pushNotifyFollows = false)
        assertEquals(false, off.pushPrefsFor(owner).follows)
        assertEquals(true, HavenConfig(ownerNpub = owner).pushPrefsFor(owner).follows)
    }
}
