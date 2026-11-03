package com.nostrvault.shareportal

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

/** The shared fixtures in HavenApp/MediaLogicTests/.../Fixtures/SharePortal (see build.gradle.kts). */
internal object ShareFixtures {
    fun load(name: String): JsonObject {
        val text = javaClass.classLoader!!.getResource(name)
            ?: error("$name not on the test classpath — check the srcDir in app/build.gradle.kts")
        return Json.parseToJsonElement(text.readText()).jsonObject
    }

    fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
    fun JsonElement.strings(): List<String> = jsonArray.map { (it as JsonPrimitive).content }

    fun input(o: JsonObject) = ShareInput(
        url = o.str("url"),
        title = o.str("title"),
        text = o.str("text"),
        selection = o.str("selection"),
        files = (o["files"] as? JsonArray)?.map { f ->
            val fo = f.jsonObject
            ShareInputFile(mime = fo.str("mime").orEmpty(), name = fo.str("name").orEmpty())
        }.orEmpty(),
        ldTypes = o["ld_types"]?.strings().orEmpty(),
    )
}
