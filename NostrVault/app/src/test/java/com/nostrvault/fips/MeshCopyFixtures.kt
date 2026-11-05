package com.nostrvault.fips

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.io.File

/** The engine lane's fixtures, docs/fixtures/mesh-copy/ (they win over the prose). Read, never written, here. */
object MeshCopyFixtures {
    private val dir: File by lazy {
        var d: File? = File(System.getProperty("user.dir")).absoluteFile
        while (d != null && !File(d, "docs/fixtures/mesh-copy").isDirectory) d = d.parentFile
        File(requireNotNull(d) { "docs/fixtures/mesh-copy not found above ${System.getProperty("user.dir")}" }, "docs/fixtures/mesh-copy")
    }

    fun raw(name: String): String = File(dir, name).readText()

    fun json(name: String): JsonObject = Json.parseToJsonElement(raw(name)) as JsonObject

    fun JsonElement.obj(): JsonObject = this as JsonObject
}
