package com.nostrvault.data.local

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Guards the Auto Backup allow-lists. Every file that can hold a key or a
 * secret must be excluded, and must never be included, in all three rule
 * sets (pre-12 backup_rules, 12+ cloud-backup, 12+ device-transfer). A new
 * secret store added to the app belongs in [secretSharedPrefs] or
 * [secretFiles] here as well.
 */
class BackupRulesTest {

    // EncryptedSharedPreferences keeps its Tink keysets inside this same file.
    private val secretSharedPrefs = listOf("nostrvault_credentials.xml")
    private val secretFiles = listOf("nostrvault_config.json", "relay_data")

    private val resDir = File("src/main/res/xml")

    private fun ruleSets(): Map<String, Element> {
        val parser = DocumentBuilderFactory.newInstance().newDocumentBuilder()
        val legacy = parser.parse(File(resDir, "backup_rules.xml")).documentElement
        val modern = parser.parse(File(resDir, "data_extraction_rules.xml")).documentElement
        return mapOf(
            "backup_rules" to legacy,
            "cloud-backup" to modern.child("cloud-backup"),
            "device-transfer" to modern.child("device-transfer"),
        )
    }

    private fun Element.child(tag: String): Element =
        getElementsByTagName(tag).item(0) as Element

    private fun Element.entries(tag: String): Set<Pair<String, String>> {
        val nodes = getElementsByTagName(tag)
        return (0 until nodes.length).map { nodes.item(it) as Element }
            .map { it.getAttribute("domain") to it.getAttribute("path") }
            .toSet()
    }

    @Test
    fun manifestPointsAtBothRuleFiles() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        assertTrue(manifest.contains("android:fullBackupContent=\"@xml/backup_rules\""))
        assertTrue(manifest.contains("android:dataExtractionRules=\"@xml/data_extraction_rules\""))
    }

    @Test
    fun everyRuleSetIsAnAllowList() {
        for ((name, set) in ruleSets()) {
            assertTrue("$name has no <include>, so everything would be backed up", set.entries("include").isNotEmpty())
        }
    }

    @Test
    fun secretsAreExcludedAndNeverIncluded() {
        for ((name, set) in ruleSets()) {
            val includes = set.entries("include")
            val excludes = set.entries("exclude")
            for (pref in secretSharedPrefs) {
                assertTrue("$name must exclude sharedpref $pref", "sharedpref" to pref in excludes)
                assertFalse("$name includes sharedpref $pref", "sharedpref" to pref in includes)
            }
            for (file in secretFiles) {
                assertTrue("$name must exclude file $file", "file" to file in excludes)
                assertFalse("$name includes file $file", "file" to file in includes)
            }
            assertFalse("$name includes the whole file root", includes.any { it.first == "file" && it.second in setOf("", ".", "/") })
            assertFalse("$name includes every shared pref", includes.any { it.first == "sharedpref" && it.second.isEmpty() })
        }
    }

    @Test
    fun threeRuleSetsStayInStep() {
        val sets = ruleSets().values.toList()
        for (other in sets.drop(1)) {
            assertEquals(sets[0].entries("include"), other.entries("include"))
            assertEquals(sets[0].entries("exclude"), other.entries("exclude"))
        }
    }

    @Test
    fun cloudBackupRequiresEncryptingTransport() {
        val cloud = ruleSets().getValue("cloud-backup")
        assertEquals("true", cloud.getAttribute("disableIfNoEncryptionCapabilities"))
    }
}
