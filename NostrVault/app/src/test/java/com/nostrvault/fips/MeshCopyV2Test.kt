package com.nostrvault.fips

import com.nostrvault.fips.MeshCopyFixtures.obj
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** docs/fixtures/mesh-copy/, case for case: the same file the engine and the Apple lane test against. */
class MeshCopyV2Test {

    @Test
    fun `every manifest case`() {
        val f = MeshCopyFixtures.json("manifest-v2-cases.json")
        val owner = f["owner"]!!.jsonPrimitive.content
        val cases = f["cases"]!!.jsonArray
        assertTrue(cases.size >= 17)
        for (c in cases.map { it.obj() }) {
            val name = c["name"]!!.jsonPrimitive.content
            val m = MeshCopyV2.manifest(c["manifest"]!!) ?: error("$name: not read")
            val expect = c["expect"]!!.obj()
            val want = if (expect["ok"]!!.jsonPrimitive.boolean) null else expect["error"]!!.jsonPrimitive.content
            assertEquals(name, want, MeshCopyV2.manifestError(m, owner))
        }
    }

    @Test
    fun `every resume case, and the third bad chunk stops`() {
        val f = MeshCopyFixtures.json("chunk-state-cases.json")
        for (c in f["cases"]!!.jsonArray.map { it.obj() }) {
            val name = c["name"]!!.jsonPrimitive.content
            val m = MeshCopyV2.manifest(c["manifest"]!!)!!
            val state = c["state"]?.takeIf { it !is JsonNull }?.obj()
            val done = state?.get("done")?.obj()?.mapValues { (_, v) -> v.jsonArray.map { it.jsonPrimitive.int } }.orEmpty()
            val plan = MeshCopyV2.plan(m, state?.get("zip_key")?.jsonPrimitive?.content, done)
            val expect = c["expect"]!!.obj()
            assertEquals(name, expect["restart"]!!.jsonPrimitive.boolean, plan.restart)
            val need = expect["need"]!!.obj().mapValues { (_, v) -> v.jsonArray.map { it.jsonPrimitive.int } }
            assertEquals(name, need, plan.need)
        }
        for (c in f["failures"]!!.jsonArray.map { it.obj() }) {
            val (failures, stop) = MeshCopyV2.chunkFailed(c["before"]!!.jsonPrimitive.int)
            val expect = c["expect"]!!.obj()
            assertEquals(expect["failures"]!!.jsonPrimitive.int, failures)
            assertEquals(expect["stop"]!!.jsonPrimitive.boolean, stop)
        }
    }

    @Test
    fun `every progress line`() {
        val cases = MeshCopyFixtures.json("progress-v2-lines.json")["cases"]!!.jsonArray.map { it.obj() }
        for (c in cases) {
            val line = c["line"]!!.jsonPrimitive.content
            val got = MeshCopyV2.parseLine(line)
            val expect = c["expect"]
            if (expect == null || expect is JsonNull) {
                assertNull(line, got)
                continue
            }
            val e = expect.obj()
            fun pair(k: String) = e[k]!!.jsonArray.let { it[0].jsonPrimitive.long to it[1].jsonPrimitive.long }
            assertEquals(
                line,
                MeshCopyV2.Line(
                    e["stage"]!!.jsonPrimitive.content, e["part"]!!.jsonPrimitive.content, pair("bytes"), pair("items"),
                    e["source"]!!.jsonPrimitive.content, e["error"]!!.jsonPrimitive.content,
                ),
                got,
            )
        }
    }

    @Test
    fun `the error table is errors-v2, code for code`() {
        val errors = MeshCopyFixtures.json("errors-v2.json")["errors"]!!.jsonArray.map { it.obj() }
        assertEquals(errors.map { it["code"]!!.jsonPrimitive.content }.toSet(), MeshCopyV2.ERROR_CODES)
        for (e in errors) {
            val code = e["code"]!!.jsonPrimitive.content
            assertEquals(code, e["b"]!!.jsonPrimitive.content, MeshCopyV2.action(code)!!.name.lowercase())
            val line = e["line"]!!.jsonPrimitive.content.replace("{name}", "Studio Mac").replace("{need}", "N").replace("{free}", "F")
            assertEquals(code, line, MeshCopyV2.errorLine(code, "Studio Mac", "N", "F"))
            e["http"]!!.jsonPrimitive.intOrNull?.let { assertEquals(code, code, MeshCopyV2.errorForHttp(it)) }
        }
    }

    @Test
    fun `needs space counts the parts twice and 1 GB`() {
        val good = MeshCopyFixtures.json("manifest-v2-cases.json")["cases"]!!.jsonArray[0].obj()["manifest"]!!
        val m = MeshCopyV2.manifest(good)!!
        val parts = 9_000_000L + 2 * MeshCopyV2.CHUNK
        assertEquals(2 * parts + (1L shl 30), MeshCopyV2.needBytes(m))
        assertNull(MeshCopyV2.spaceLine(m, MeshCopyV2.needBytes(m), "Pixel"))
        assertEquals("Needs 1.1 GB free, this device has 0.5 GB", MeshCopyV2.spaceLine(m, 1L shl 29, "Pixel"))
        // The need rounds up, the free space down: never "Needs 1.0 GB, this device has 1.0 GB".
        assertEquals("Needs 1.1 GB free, this device has 1.0 GB", MeshCopyV2.spaceLine(m, MeshCopyV2.needBytes(m) - 1, "Pixel"))
    }

    @Test
    fun `the start is signed for the path A checks, never the link's own secret`() {
        val (base, prefix) = MeshCopyV2.splitLink("ws://127.0.0.1:40123/" + "f".repeat(64))!!
        assertEquals("http://127.0.0.1:40123", base)
        assertEquals("/" + "f".repeat(64), prefix)
        val tags = MeshKeyAuth.copyStartTags(base, "npub1peer")!!
        assertEquals(listOf(listOf("u", "http://127.0.0.1:40123/copy/v2/start"), listOf("method", "POST"), listOf("p", "npub1peer")), tags)
        assertFalse(tags.flatten().any { "f".repeat(64) in it })
    }

    @Test
    fun `a start answer needs a 32-hex id and a 64-hex token`() {
        val id = "a".repeat(32)
        val token = "b".repeat(64)
        assertEquals(MeshCopyV2.Started(id, token), MeshCopyV2.parseStart("""{"id":"$id","token":"$token","state":"building"}"""))
        assertNull(MeshCopyV2.parseStart("""{"id":"$id","token":"short"}"""))
        assertNull(MeshCopyV2.parseStart("""{"id":"${id.uppercase()}","token":"$token"}"""))
        assertNull(MeshCopyV2.parseStart("not json"))
    }

    @Test
    fun `status lines name the device and the refused settings`() {
        val done = MeshCopyV2.parseLine("COPY stage=done part=- bytes=0/0 items=5/5 source=mesh error=settings_refused")!!
        assertEquals("Settings weren't copied: they held something that must stay on Studio Mac", MeshCopyV2.statusText(done, "Studio Mac"))
        val fetching = MeshCopyV2.parseLine("COPY stage=fetching part=notes bytes=4194304/9000000 items=1/3 source=mesh")!!
        assertEquals("Copying notes from Studio Mac: 46%", MeshCopyV2.statusText(fetching, "Studio Mac"))
        // The engine's needs_space line carries free/need; the words come from it, not from this device.
        val space = MeshCopyV2.parseLine("COPY stage=failed part=- bytes=1000/1092993024 items=0/0 source=mesh error=needs_space")!!
        assertEquals("Needs 1.1 GB free, this device has 0.0 GB", MeshCopyV2.statusText(space, "Studio Mac"))
    }
}
