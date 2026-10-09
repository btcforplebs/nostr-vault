package com.nostrvault.tutorials

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The cards say the same thing on both platforms. Reads the iOS
 * `TutorialContent.swift` from the same checkout, so a wording change made
 * on one side only fails here instead of drifting.
 */
class TutorialWordingParityTest {
    private val swift = File("../../HavenApp/HavenApp/Models/TutorialContent.swift")

    @Test fun cardsMatchIos() {
        assertTrue("iOS file not found at ${swift.absolutePath}", swift.isFile)
        val step = Regex("""title:\s*"((?:[^"\\]|\\.)*)",\s*body:\s*"((?:[^"\\]|\\.)*)"""")
        val ios = step.findAll(swift.readText()).map { it.groupValues[1] to it.groupValues[2] }.toList()
        // Same order as the Swift file.
        val android = (TutorialContent.feeds + TutorialContent.wot + TutorialContent.vault +
            TutorialContent.walletConnect + TutorialContent.pocketRelay + TutorialContent.importTour)
            .map { it.title to it.body }
        assertEquals(android.size, ios.size)
        android.zip(ios).forEach { (a, i) -> assertEquals(i.first to (meshReach[i.second] ?: i.second), a) }
    }

    /** Who can reach your vault over the FIPS mesh differs by platform: iOS
     *  Kiosk mode opens it to anyone on the mesh, Android's Share my relay
     *  only to the friends you add. These are the only cards allowed to
     *  differ, iOS body to Android body. */
    private val meshReach = mapOf(
        "Public relays are shared servers that anyone can post to. Your vault is personal: this address only works on this phone, so nobody else can connect to it unless you turn on Kiosk mode in Settings. If you want a public address that's always on, run Nostr Vault on a Mac with your own domain. That part is optional." to
            "Public relays are shared servers that anyone can post to. Your vault is personal: this address only works on this phone, so nobody else can connect to it unless you turn on Share my relay under Mesh in Settings and add the friends who can reach you. If you want a public address that's always on, run Nostr Vault on a Mac with your own domain. That part is optional.",
        "Nostr Vault runs a personal relay and a Blossom media server on your phone. It keeps everything and sends your posts out to the relays you pick. Nobody on the network can connect to it unless you turn on Kiosk mode." to
            "Nostr Vault runs a personal relay and a Blossom media server on your phone. It keeps everything and sends your posts out to the relays you pick. Nobody on the network can connect to it unless you turn on mesh sharing.",
    )

    @Test fun meshReachDiffersOnlyWhereListed() {
        val text = swift.readText()
        meshReach.keys.forEach { assertTrue("iOS no longer says: $it", text.contains(it)) }
    }

    @Test fun summariesMatchIos() {
        val text = swift.readText()
        val block = text.substringAfter("var summary: String {").substringBefore("var symbolName")
        val cases = Regex("""case \.(\w+): return "((?:[^"\\]|\\.)*)"""").findAll(block)
            .associate { it.groupValues[1] to it.groupValues[2] }
        assertEquals(TutorialID.entries.size, cases.size)
        TutorialID.entries.forEach { id ->
            val swiftName = id.name.lowercase().split('_')
                .mapIndexed { i, w -> if (i == 0) w else w.replaceFirstChar { it.uppercase() } }.joinToString("")
            assertEquals(id.name, cases[swiftName], id.summary)
        }
    }
}
