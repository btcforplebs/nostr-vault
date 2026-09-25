package com.nostrvault.service

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Test

class SignedEventSerializationTest {

    private val tricky = "tab\there \\ back \"quote\" ¯\\_(ツ)_/¯ \r\n bell\u0007 émoji 🐝"

    private val event = NostrEvent(
        id = "a".repeat(64),
        pubkey = "b".repeat(64),
        createdAt = 1790250000,
        kind = 0,
        tags = listOf(listOf("t", "has \"quote\" and \\slash"), listOf("client", "Nostr Vault on Android")),
        content = """{"about":"line one\nline two \"quoted\" \\ back"}""" + tricky,
        sig = "c".repeat(128),
    )

    @Test
    fun `wire form parses back to exactly the signed fields`() {
        val obj = Json.parseToJsonElement(EventPublisher.serializeSignedEvent(event)).jsonObject
        assertEquals(event.id, obj["id"]!!.jsonPrimitive.content)
        assertEquals(event.pubkey, obj["pubkey"]!!.jsonPrimitive.content)
        assertEquals(event.createdAt, obj["created_at"]!!.jsonPrimitive.long)
        assertEquals(event.kind, obj["kind"]!!.jsonPrimitive.int)
        assertEquals(event.content, obj["content"]!!.jsonPrimitive.content)
        assertEquals(event.tags, obj["tags"]!!.jsonArray.map { t -> t.jsonArray.map { it.jsonPrimitive.content } })
        assertEquals(event.sig, obj["sig"]!!.jsonPrimitive.content)
    }
}
