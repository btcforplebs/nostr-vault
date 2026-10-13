package com.nostrvault.widget

import org.junit.Assert.assertEquals
import org.junit.Test

/** The one-cell widget (iOS `LockScreenView`): what it reads and where a tap goes. */
class VaultGlanceTest {

    private fun note(id: String) = VaultSnapshot.SnapshotNote(id = id, author = "a", displayName = "A", text = "hi", createdAt = 0L)

    private val snapshot = VaultSnapshot(
        relay = VaultSnapshot.RelayStats(running = true, eventsStored = 12_345, connections = 2),
        mentions = listOf(note("1"), note("2"), note("3")),
        unreadDMs = 4,
    )

    @Test fun vaultStatusSaysLiveOrOff() {
        assertEquals(GlanceReading("Live", "vault", live = true), glanceReading(GlanceMetric.RELAY, snapshot))
        val down = snapshot.copy(relay = snapshot.relay.copy(running = false))
        assertEquals(GlanceReading("Off", "vault", live = false), glanceReading(GlanceMetric.RELAY, down))
    }

    @Test fun countsComeFromTheSnapshot() {
        assertEquals(GlanceReading("3", "mentions"), glanceReading(GlanceMetric.MENTIONS, snapshot))
        assertEquals(GlanceReading("4", "messages"), glanceReading(GlanceMetric.DMS, snapshot))
        assertEquals(GlanceReading("12k", "events"), glanceReading(GlanceMetric.EVENTS, snapshot))
    }

    @Test fun anEmptySnapshotReadsAsOffAndZero() {
        val empty = VaultSnapshot()
        assertEquals("Off", glanceReading(GlanceMetric.RELAY, empty).value)
        assertEquals("0", glanceReading(GlanceMetric.MENTIONS, empty).value)
        assertEquals("0", glanceReading(GlanceMetric.EVENTS, empty).value)
    }

    @Test fun countsFitOneCell() {
        assertEquals("950", compactCount(950))
        assertEquals("1k", compactCount(1_000))
        assertEquals("1.2k", compactCount(1_250))
        assertEquals("9.9k", compactCount(9_999))
        assertEquals("34k", compactCount(34_567))
        assertEquals("1.2M", compactCount(1_234_567))
        assertEquals("12M", compactCount(12_345_678))
    }

    @Test fun theChoiceFallsBackOnVaultStatus() {
        assertEquals(GlanceMetric.RELAY, GlanceMetric.from { null })
        assertEquals(GlanceMetric.RELAY, GlanceMetric.from { "WEATHER" })
        val saved = GlanceMetric.toEntries(GlanceMetric.DMS)
        assertEquals(GlanceMetric.DMS, GlanceMetric.from { saved[it] })
    }

    @Test fun aTapOpensWhatTheNumberIsAbout() {
        assertEquals("relay", GlanceMetric.RELAY.destination)
        assertEquals("mentions", GlanceMetric.MENTIONS.destination)
        assertEquals("dms", GlanceMetric.DMS.destination)
        assertEquals("relay", GlanceMetric.EVENTS.destination)
        assertEquals("wallet", GlanceMetric.ZAPS.destination)
    }

    @Test fun zapsShowTodaysCountAndZeroOnceTheDayHasChanged() {
        val today = 1_760_400_000L
        val counted = snapshot.copy(zapsToday = VaultSnapshot.ZapCount(account = "me", dayStart = today, count = 7))
        assertEquals(GlanceReading("7", "zaps today"), glanceReading(GlanceMetric.ZAPS, counted, todayStart = today))
        // Drawn after midnight, before the next count: yesterday's 7 is not today's.
        assertEquals(GlanceReading("0", "zaps today"), glanceReading(GlanceMetric.ZAPS, counted, todayStart = today + 86_400))
        assertEquals("0", glanceReading(GlanceMetric.ZAPS, VaultSnapshot(), todayStart = today).value)
    }

    @Test fun aCountIsHeldOnlyForItsAccountAndDay() {
        val today = 1_760_400_000L
        val alice = VaultSnapshot.ZapCount(account = "alice", dayStart = today, count = 7)
        // Same account, same day: kept while the next count runs.
        assertEquals(alice, alice.heldFor("alice", today))
        // Another account: 0 for them, never alice's 7.
        val bob = alice.heldFor("bob", today)
        assertEquals(VaultSnapshot.ZapCount(account = "bob", dayStart = today, count = 0), bob)
        assertEquals("0", glanceReading(GlanceMetric.ZAPS, snapshot.copy(zapsToday = bob), todayStart = today).value)
        // A new day: 0, for the new day.
        assertEquals(VaultSnapshot.ZapCount(account = "alice", dayStart = today + 86_400, count = 0), alice.heldFor("alice", today + 86_400))
    }

    @Test fun aCountForAnotherAccountOrDayNeverLands() {
        val today = 1_760_400_000L
        // Switched to bob: his 0 is held while alice's count was still running.
        val held = VaultSnapshot.ZapCount(account = "alice", dayStart = today, count = 7).heldFor("bob", today)
        val lateForAlice = VaultSnapshot.ZapCount(account = "alice", dayStart = today, count = 9)
        assertEquals(held, held.accept(lateForAlice))
        assertEquals("0", glanceReading(GlanceMetric.ZAPS, snapshot.copy(zapsToday = held.accept(lateForAlice)), todayStart = today).value)
        // Yesterday's count landing after midnight's 0.
        val yesterdays = VaultSnapshot.ZapCount(account = "bob", dayStart = today - 86_400, count = 4)
        assertEquals(held, held.accept(yesterdays))
        // Bob's own count for today does land.
        val bobs = VaultSnapshot.ZapCount(account = "bob", dayStart = today, count = 3)
        assertEquals(bobs, held.accept(bobs))
    }
}
