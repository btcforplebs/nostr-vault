package com.nostrvault.fips

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/**
 * Two-scan pairing against the fixtures iOS (MeshPairingTests.swift) and the web read too
 * (HavenApp/MediaLogicTests/Tests/MediaLogicTests/Fixtures/MeshPairing, made by reference.py).
 */
class MeshPairingTest {
    private val dir: File = listOf("../../HavenApp", "../HavenApp", "HavenApp").map { File(it) }
        .first { it.isDirectory }.resolve("MediaLogicTests/Tests/MediaLogicTests/Fixtures/MeshPairing")

    private fun fixture(name: String): JsonObject = Json.parseToJsonElement(dir.resolve(name).readText()).jsonObject
    private fun JsonObject.str(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonObject.long(k: String): Long = this[k]!!.jsonPrimitive.long
    private fun JsonObject.strings(k: String): List<String> = (this[k] as? JsonArray)?.map { it.jsonPrimitive.content }.orEmpty()
    private fun role(s: String?): DeviceRole = MeshPairing.roleFromWire(s) ?: error("role $s")

    @Test fun parse() {
        val cases = fixture("payload-cases.json")["parse"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size > 30)
        for (c in cases) {
            val name = c.str("name")
            val got = MeshPairing.parse(c.str("uri")!!, c.str("own"))
            val expect = c["expect"]!!.jsonObject
            val refusal = expect.str("refusal")
            if (refusal != null) {
                assertEquals(name, refusal, (got as? MeshPairing.Parsed.Refused)?.refusal?.code)
                continue
            }
            val p = expect["payload"]!!.jsonObject
            val payload = (got as? MeshPairing.Parsed.Ok)?.payload ?: error("$name: $got")
            assertEquals(name, p.str("mesh"), payload.mesh)
            assertEquals(name, p.str("mesh_hex"), payload.meshHex)
            assertEquals(name, p.str("name"), payload.name)
            assertEquals(name, role(p.str("role")), payload.role)
            assertEquals(name, p.str("owner"), payload.owner)
            assertEquals(name, p.str("owner_hex"), payload.ownerHex)
            p.str("secret")?.let { assertEquals(name, MeshPairing.Code.Secret(it), payload.code) }
            p.str("echo")?.let { assertEquals(name, MeshPairing.Code.Echo(it), payload.code) }
        }
    }

    @Test fun build() {
        val fx = fixture("payload-cases.json")
        val rule = fx["rule"]!!.jsonObject
        assertEquals(rule["name_max"]!!.jsonPrimitive.int, MeshPairing.NAME_MAX)
        assertEquals(rule.strings("roles"), MeshPairing.WIRE_ROLES.map { it.first })
        for (c in fx["build"]!!.jsonArray.map { it.jsonObject }) {
            val a = c["args"]!!.jsonObject
            val code = a.str("s")?.let { MeshPairing.Code.Secret(it) } ?: MeshPairing.Code.Echo(a.str("e")!!)
            val uri = MeshPairing.build(a.str("m")!!, a.str("n")!!, role(a.str("r")), a.str("o")!!, code)
            assertEquals(c.str("name"), c.str("expect"), uri)
            assertTrue(MeshPairing.parse(uri, null) is MeshPairing.Parsed.Ok)
        }
    }

    @Test fun ownerAndRole() {
        val fx = fixture("payload-cases.json")
        for (c in fx["owner"]!!.jsonArray.map { it.jsonObject }) {
            val active = (c["active"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
            val got = when (val r = MeshPairing.ownerCheck(c.str("owner")!!, active, c.strings("accounts"))) {
                MeshPairing.OwnerCheck.Ok -> "ok"
                is MeshPairing.OwnerCheck.SwitchTo -> "switchTo:" + r.npub
                MeshPairing.OwnerCheck.OtherOwner -> "otherOwner"
            }
            assertEquals(c.str("name"), c.str("expect"), got)
        }
        for (c in fx["role"]!!.jsonArray.map { it.jsonObject }) {
            val existing = c["existing"]!!.jsonArray.map { it.jsonObject }.map { it.str("npub")!! to role(it.str("role")) }
            val got = when (val r = MeshPairing.roleCheck(c.str("npub")!!, role(c.str("role")), existing)) {
                MeshPairing.RoleCheck.Add -> "add"
                MeshPairing.RoleCheck.AlreadyLinked -> "alreadyLinked"
                is MeshPairing.RoleCheck.RefuseOtherRole -> "refuseOtherRole:" + MeshPairing.wire(r.role)
            }
            assertEquals(c.str("name"), c.str("expect"), got)
        }
    }

    @Test fun texts() {
        for (c in fixture("payload-cases.json")["texts"]!!.jsonArray.map { it.jsonObject }) {
            val expect = c.str("expect")
            when (c.str("kind")) {
                "confirm" -> assertEquals(expect, MeshPairing.roleConfirmText(role(c.str("role")), c.str("name")!!,
                    (c["setup"] as? JsonPrimitive)?.booleanOrNull ?: false))
                "short" -> assertEquals(expect, MeshPairing.shortAddress(c.str("npub")!!))
                else -> {
                    val code = c.str("code")!!
                    val got = when (code) {
                        "otherOwner" -> MeshPairing.OTHER_OWNER_TEXT
                        "alreadyLinked" -> MeshPairing.ALREADY_LINKED_TEXT
                        "expired" -> MeshPairing.EXPIRED_TEXT
                        "abort" -> MeshPairing.ABORT_TEXT
                        "switchTo" -> MeshPairing.switchToText(c.str("account_name")!!)
                        "refuseOtherRole" -> MeshPairing.otherRoleText(role(c.str("role")))
                        else -> MeshPairing.text(MeshPairing.Refusal.entries.first { it.code == code })
                    }
                    assertEquals(code, expect, got)
                }
            }
        }
    }

    @Test fun helloAndAckBuilders() {
        val fx = fixture("hello-cases.json")
        val rule = fx["rule"]!!.jsonObject
        assertEquals(rule.long("hello_kind"), MeshPairing.HELLO_KIND.toLong())
        assertEquals(rule.long("code_lifetime"), MeshPairing.CODE_LIFETIME)
        assertEquals(rule.long("scan_window"), MeshPairing.SCAN_WINDOW)
        assertEquals(rule.long("ack_window"), MeshPairing.ACK_WINDOW)
        assertEquals(rule.long("hello_skew"), MeshPairing.HELLO_SKEW)
        for (b in fx["builders"]!!.jsonArray.map { it.jsonObject }) {
            val a = b["args"]!!.jsonObject
            val got = if (b.str("kind") == "ack") {
                MeshPairing.ackJson(a.str("d")!!, a["w"]!!.jsonPrimitive.booleanOrNull!!)
            } else {
                MeshPairing.helloJson(a.str("s")!!, a.str("n")!!, role(a.str("r")), a.str("o")!!, a.long("t"))
            }
            assertEquals(b.str("expect"), got)
        }
    }

    @Test fun sessions() {
        val cases = fixture("hello-cases.json")["cases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size > 30)
        for (c in cases) {
            val name = c.str("name")
            val steps = c["steps"]!!.jsonArray.map { it.jsonObject }
            if (c.str("side") == "joiner") {
                val a = (MeshPairing.parse(c.str("qr_a")!!, null) as MeshPairing.Parsed.Ok).payload
                val j = MeshPairingJoiner.start(a, c.str("own_mesh")!!, c.long("scanned_at"))!!
                steps.forEachIndexed { i, st ->
                    val got = if (st.str("op") == "words") j.confirmWords() else j.receiveAck(st.str("sender")!!, st.str("content")!!, st.long("now"))
                    assertEquals("$name step $i", st.str("expect"), code(got))
                }
                continue
            }
            val active = (c["active"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
            val s = MeshPairingSession(c.str("secret")!!, c.long("created_at"), c.str("own_mesh")!!, active, c.strings("accounts"))
            steps.forEachIndexed { i, st ->
                val now = st.long("now")
                val got = when (st.str("op")) {
                    "hello" -> s.receiveHello(st.str("sender")!!, st.str("content")!!, now)
                    "qr" -> s.acceptSecondQR(st.str("uri")!!, now)
                    else -> s.acceptWithoutScan(now)
                }
                assertEquals("$name step $i", st.str("expect"), code(got))
            }
        }
    }

    @Test fun confirmCarriesTheHellosDevice() {
        val c = fixture("hello-cases.json")["cases"]!!.jsonArray.map { it.jsonObject }.first { it.str("name")!!.startsWith("happy path") }
        val steps = c["steps"]!!.jsonArray.map { it.jsonObject }
        val s = MeshPairingSession(c.str("secret")!!, c.long("created_at"), c.str("own_mesh")!!, c.str("active"), c.strings("accounts"))
        s.receiveHello(steps[0].str("sender")!!, steps[0].str("content")!!, steps[0].long("now"))
        val got = s.acceptSecondQR(steps[1].str("uri")!!, steps[1].long("now")) as MeshPairingSession.Outcome.Confirm
        assertEquals(steps[0].str("sender"), MeshPairing.npubHex(got.npub))
        assertEquals("Logen's iPhone", got.name)
        assertEquals(DeviceRole.PHONE, got.role)
    }

    @Test fun checkWordsAndAckDigest() {
        val fx = fixture("checkwords-cases.json")
        val list = dir.resolve("words.txt").readBytes()
        val sha = MessageDigest.getInstance("SHA-256").digest(list).joinToString("") { "%02x".format(it) }
        assertEquals(fx["rule"]!!.jsonObject.str("list_sha256"), sha)
        assertEquals(String(list).split("\n").filter { it.isNotEmpty() }, MeshPairingWords.list)
        assertEquals(2048, MeshPairingWords.list.size)
        for (c in fx["cases"]!!.jsonArray.map { it.jsonObject }) {
            assertEquals(c.strings("words"), MeshPairing.checkWords(c.str("a")!!, c.str("b")!!, c.str("secret")!!))
            assertEquals(c.str("ack_digest"), MeshPairing.ackDigest(c.str("secret")!!, c.str("a")!!, c.str("b")!!))
        }
    }

    @Test fun newSecretIsFreshAndReadable() {
        val a = MeshPairing.newSecret()
        assertNotEquals(a, MeshPairing.newSecret())
        assertNotNull(MeshPairing.secretBytes(a))
        assertEquals(22, a.length)
    }

    private fun code(o: MeshPairingSession.Outcome): String = when (o) {
        is MeshPairingSession.Outcome.Camera -> "camera"
        MeshPairingSession.Outcome.IgnoreDuplicate -> "ignoreDuplicate"
        MeshPairingSession.Outcome.Abort -> "abort"
        MeshPairingSession.Outcome.Expired -> "expired"
        is MeshPairingSession.Outcome.Ignore -> "ignore:" + o.why
        is MeshPairingSession.Outcome.Refuse -> "refuse:" + o.why
        is MeshPairingSession.Outcome.Confirm -> "confirm"
        is MeshPairingSession.Outcome.Reject -> "reject:" + o.why
        is MeshPairingSession.Outcome.Unreadable -> "refuse:" + o.refusal.code
    }

    private fun code(o: MeshPairingJoiner.Outcome): String = when (o) {
        MeshPairingJoiner.Outcome.Linked -> "linked"
        MeshPairingJoiner.Outcome.WaitWords -> "waitWords"
        MeshPairingJoiner.Outcome.WaitAck -> "waitAck"
        MeshPairingJoiner.Outcome.IgnoreDuplicate -> "ignoreDuplicate"
        MeshPairingJoiner.Outcome.Expired -> "expired"
        is MeshPairingJoiner.Outcome.Ignore -> "ignore:" + o.why
    }
}
