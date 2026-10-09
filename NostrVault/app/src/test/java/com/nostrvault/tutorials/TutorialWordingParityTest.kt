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
        val ios = step.findAll(swift.readText())
            .map { it.groupValues[1] to it.groupValues[2].replace("\\\"", "\"") }.toList()
        // Same order as the Swift file.
        val android = (TutorialContent.feeds + TutorialContent.wot + TutorialContent.vault +
            TutorialContent.walletConnect + TutorialContent.pocketRelay + TutorialContent.importTour)
            .map { it.title to it.body }
        assertEquals(android.size, ios.size)
        android.zip(ios).forEach { (a, i) -> assertEquals(i, a) }
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
