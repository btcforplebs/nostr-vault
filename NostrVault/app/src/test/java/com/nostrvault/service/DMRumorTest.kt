package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** A kind 15 rumor is the web's rumorFor(me, peer, url, at, { kind: 15, tags }): p first, then the file tags. */
class DMRumorTest {
    @Test
    fun `a file rumor is kind 15 with p then the file tags, dated no earlier than asked`() {
        val enc = DMFile.encrypt("x".toByteArray())
        val msg = DMFile.fileMessage("https://files.example/${enc.x}", enc, "image/png")
        val later = System.currentTimeMillis() / 1000 + 100
        val o = Json.parseToJsonElement(DMRumor.file(msg, later).build("a".repeat(64), "b".repeat(64), msg.content)).jsonObject
        assertEquals(15, o["kind"]!!.jsonPrimitive.int)
        assertEquals(msg.content, o["content"]!!.jsonPrimitive.content)
        val tags = o["tags"]!!.jsonArray.map { t -> t.jsonArray.map { it.jsonPrimitive.content } }
        assertEquals(listOf(listOf("p", "b".repeat(64))) + msg.tags, tags)
        assertTrue(o["created_at"]!!.jsonPrimitive.long >= later)
    }

    @Test
    fun `a plain rumor is still kind 14 with only its p`() {
        val o = Json.parseToJsonElement(DMRumor().build("a".repeat(64), "b".repeat(64), "hi")).jsonObject
        assertEquals(14, o["kind"]!!.jsonPrimitive.int)
        assertEquals(1, o["tags"]!!.jsonArray.size)
    }
}
