package com.nostrvault.service.translate

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MozillaModelCatalogTest {

    private fun record(
        from: String,
        to: String,
        version: String,
        type: String,
        name: String = "$type.$from$to.$version.bin",
        filter: String? = "",
        hash: String = "AB${type.length}",
    ) = """
        {"fromLang":"$from","toLang":"$to","version":"$version","fileType":"$type","name":"$name",
         ${if (filter == null) "" else "\"filter_expression\":\"$filter\","}
         "attachment":{"filename":"$name","location":"main-workspace/translations-models/$name","hash":"$hash","size":10}}
    """.trimIndent()

    private fun full(from: String, to: String, version: String, filter: String? = "") = listOf(
        record(from, to, version, "model", filter = filter),
        record(from, to, version, "lex", filter = filter),
        record(from, to, version, "vocab", filter = filter),
    )

    private fun catalog(vararg records: String) = """{"data":[${records.joinToString(",")}]}"""

    @Test
    fun `picks the newest release and ignores pre-releases`() {
        val json = catalog(*(full("es", "en", "1.0") + full("es", "en", "2.0") + full("es", "en", "2.1a1")).toTypedArray())
        val set = MozillaModelCatalog.pick(json, "es", "en")!!
        assertEquals("2.0", set.version)
        assertEquals("model.esen.2.0.bin", set.model.fileName)
        assertEquals(
            "https://firefox-settings-attachments.cdn.mozilla.net/main-workspace/translations-models/model.esen.2.0.bin",
            set.model.url,
        )
        assertEquals("ab5", set.model.sha256)
    }

    @Test
    fun `versions compare as numbers`() {
        val json = catalog(*(full("en", "de", "2.9") + full("en", "de", "2.10")).toTypedArray())
        assertEquals("2.10", MozillaModelCatalog.pick(json, "en", "de")!!.version)
    }

    @Test
    fun `takes Android-only records and skips channel and not-Android ones`() {
        val json = catalog(
            *(full("en", "ja", "2.1", "env.appinfo.OS != 'Android' || env.channel != 'release'") +
                full("en", "ja", "2.2", "env.appinfo.OS == 'Android' ") +
                full("en", "ja", "3.0", "env.channel == 'default' || env.channel == 'nightly'")).toTypedArray(),
        )
        assertEquals("2.2", MozillaModelCatalog.pick(json, "en", "ja")!!.version)
    }

    @Test
    fun `a record with no filter field counts as unfiltered`() {
        val json = catalog(*full("fr", "en", "1.0", filter = null).toTypedArray())
        assertEquals("1.0", MozillaModelCatalog.pick(json, "fr", "en")!!.version)
    }

    @Test
    fun `an incomplete newest version falls back to the last complete one`() {
        val json = catalog(
            *(full("it", "en", "1.0") + record("it", "en", "2.0", "model") + record("it", "en", "2.0", "vocab")).toTypedArray(),
        )
        assertEquals("1.0", MozillaModelCatalog.pick(json, "it", "en")!!.version)
    }

    @Test
    fun `separate source and target vocabularies are used in order`() {
        val json = catalog(
            record("en", "zh-Hans", "1.0", "model"),
            record("en", "zh-Hans", "1.0", "lex"),
            record("en", "zh-Hans", "1.0", "trgvocab", name = "trgvocab.bin"),
            record("en", "zh-Hans", "1.0", "srcvocab", name = "srcvocab.bin"),
        )
        val set = MozillaModelCatalog.pick(json, "en", "zh-Hans")!!
        assertEquals(listOf("srcvocab.bin", "trgvocab.bin"), set.vocabs.map { it.fileName })
    }

    @Test
    fun `one shared vocabulary serves both sides`() {
        val set = MozillaModelCatalog.pick(catalog(*full("de", "en", "2.0").toTypedArray()), "de", "en")!!
        assertEquals(2, set.vocabs.size)
        assertEquals(set.vocabs[0], set.vocabs[1])
    }

    @Test
    fun `no model for a direction is null`() {
        assertNull(MozillaModelCatalog.pick(catalog(*full("es", "en", "2.0").toTypedArray()), "en", "es"))
        assertNull(MozillaModelCatalog.pick("""{"data":[]}""", "es", "en"))
    }

    @Test
    fun `file names that are paths are refused`() {
        val json = catalog(
            record("es", "en", "1.0", "model", name = "../evil.bin"),
            record("es", "en", "1.0", "lex"),
            record("es", "en", "1.0", "vocab"),
        )
        assertNull(MozillaModelCatalog.pick(json, "es", "en"))
    }

    @Test
    fun `bergamot config matches Firefox settings`() {
        val yaml = MozillaModelCatalog.bergamotConfig("/m/model.esen.intgemm.alphas.bin", "/m/v.spm", "/m/v.spm", "/m/lex.bin")
        assertTrue(yaml.contains("  - \"/m/model.esen.intgemm.alphas.bin\"\n"))
        assertTrue(yaml.contains("shortlist:\n  - \"/m/lex.bin\"\n  - false\n"))
        assertTrue(yaml.contains("gemm-precision: int8shiftAlphaAll\n"))
        assertTrue(yaml.contains("beam-size: 1\n"))
        assertTrue(yaml.contains("cpu-threads: 0\n"))
        assertEquals("gemm-precision: int8shiftAll", MozillaModelCatalog.bergamotConfig("/m/model.bin", "a", "b", "c")
            .lines().first { it.startsWith("gemm-precision") })
    }
}
