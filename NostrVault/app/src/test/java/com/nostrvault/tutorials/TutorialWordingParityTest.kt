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

    /** `static let wotGlobe = "wot.globe"` and friends, by Swift name. */
    private fun swiftAnchors(text: String) =
        Regex("""static let (\w+) = "([a-z]+\.[a-z-]+)"""").findAll(text)
            .associate { it.groupValues[1] to it.groupValues[2] }

    /** Title, body and the anchor each card points at. */
    @Test fun cardsMatchIos() {
        assertTrue("iOS file not found at ${swift.absolutePath}", swift.isFile)
        val text = swift.readText()
        val anchors = swiftAnchors(text)
        val step = Regex(
            """TutorialStep\(\s*anchor:\s*(\w+),\s*title:\s*"((?:[^"\\]|\\.)*)",\s*body:\s*"((?:[^"\\]|\\.)*)"\s*\)""",
        )
        val ios = step.findAll(text).map {
            val name = it.groupValues[1]
            val anchor = if (name == "nil") null else checkNotNull(anchors[name]) { "iOS anchor $name has no value" }
            TutorialStep(anchor, it.groupValues[2], it.groupValues[3].replace("\\\"", "\""))
        }.toList()
        // Every step must match the regex. A `"""` body or a reordered
        // argument would otherwise drop out and show up as a size mismatch.
        assertEquals(
            "a TutorialStep in the Swift file isn't `anchor:, title: \"…\", body: \"…\"` on single-line literals",
            Regex("""TutorialStep\(""").findAll(text).count(), ios.size,
        )
        // Same order as the Swift file.
        val android = TutorialContent.feeds + TutorialContent.wot + TutorialContent.vault +
            TutorialContent.walletConnect + TutorialContent.pocketRelay + TutorialContent.importTour
        assertEquals(android.size, ios.size)
        android.zip(ios).forEach { (a, i) -> assertEquals(i, a) }
    }

    /** Each iOS anchor constant has an Android one with the same value:
     *  `wotGlobe` ↔ `WOT_GLOBE`. Read from the Swift file, not restated here. */
    @Test fun anchorNamesMatchIos() {
        val anchors = swiftAnchors(swift.readText())
        assertTrue(anchors.toString(), anchors.size >= 12)
        anchors.forEach { (name, value) ->
            val kotlin = name.replace(Regex("([A-Z])"), "_$1").uppercase()
            val field = runCatching { TutorialContent::class.java.getField(kotlin) }.getOrNull()
            assertTrue("Android has no TutorialContent.$kotlin for iOS $name", field != null)
            assertEquals(name, value, field!!.get(null))
        }
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
