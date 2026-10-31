package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * Kind 10063 goes out only from Save in Media servers (Logen 2026-10-31).
 * Reading a list and My Devices changes used to republish it on their own.
 */
class ServerListPublishOnlyOnSaveTest {

    @Test
    fun `publishServerList is called only by Media servers Save`() {
        val callers = File("src/main/java").walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { f -> f.readLines().any { "publishServerList(" in it && "fun publishServerList" !in it } }
            .map { it.name }
            .toList()
        assertEquals(listOf("BlossomSettingsScreen.kt"), callers)
    }
}
