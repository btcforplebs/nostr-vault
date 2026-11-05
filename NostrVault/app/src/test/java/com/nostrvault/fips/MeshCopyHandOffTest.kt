package com.nostrvault.fips

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission

/** The copy token handed to the engine: whole (no `.partial` left), and readable by this app only. */
class MeshCopyHandOffTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test
    fun `the hand-off is written whole and owner-only`() {
        val dir = tmp.newFolder("relay_data")
        val m = MeshCopyV2.Manifest(2, "a".repeat(32), "ready", "", "o", emptyList(), "k".repeat(64), "none")
        val ready = MeshCopyClient.Result.Ready(MeshCopyV2.Started("a".repeat(32), "b".repeat(64)), m)
        MeshCopyStarter.handOff(dir, "ws://127.0.0.1:1/t", ready)
        val f = File(dir, MeshCopyStarter.HANDOFF_FILE)
        val o = Json.parseToJsonElement(f.readText()) as JsonObject
        assertEquals("b".repeat(64), o["token"]!!.jsonPrimitive.content)
        assertEquals("ws://127.0.0.1:1/t", o["link"]!!.jsonPrimitive.content)
        assertFalse(File(dir, "${MeshCopyStarter.HANDOFF_FILE}.partial").exists())
        assertEquals(setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE), Files.getPosixFilePermissions(f.toPath()))
    }
}
