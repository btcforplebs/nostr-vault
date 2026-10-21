package com.nostrvault.data.model

import com.nostrvault.data.model.GlobeZapsFixtures.badSig
import com.nostrvault.data.model.GlobeZapsFixtures.duplicatePubkey
import com.nostrvault.data.model.GlobeZapsFixtures.otherSigner
import com.nostrvault.data.model.GlobeZapsFixtures.rebuilt
import com.nostrvault.data.model.GlobeZapsFixtures.signed
import com.nostrvault.data.model.GlobeZapsFixtures.unsigned
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * Mirrors HavenApp/MediaLogicTests/Tests/MediaLogicTests/GlobeZapsTests.swift, with
 * its go-nostr signed fixtures (throwaway keys) and recorded verdicts. go-nostr is
 * what the app's verifier runs (HavenBridge.verifyEvent → VerifyEventC).
 */
class GlobeZapsTest {
    private val me = "0".repeat(64)
    private val server = "5".repeat(64)
    private val zapper = "a".repeat(64)
    private val zapped = "b".repeat(64)
    private val now = 1_800_000_000.0

    private val signedZapper = "74dc4c285760501bf074a8c0f23188fc0fa85f408311fc3c474b8f76b488c84d"
    private val victim = "51a6f6ca66bc75f0dd2fbc883b409f1e74a49e9da6c58007bf54317a2e4418ff"
    /** Who actually signed the duplicate-key request: the attacker, the last `pubkey`. */
    private val attacker = "5c99b266d2c29ba7e86fcf598ad304ca04e8925f65d9cdc113487f95ac1898a3"

    /**
     * kotlinx reads a key given twice last-wins (Swift reads first-wins), so the
     * duplicate-key request is rebuilt here as the attacker's own request. go-nostr
     * v0.52.3 verified this exact text as true (run 2026-10-15): the attacker can
     * draw a bolt only from themself, never from the victim.
     */
    private val duplicateRebuiltHere =
        """{"content":"for the bolt","created_at":1799999990,"id":"2f5b4b449b350d49d32afee5ae4a99f568d936250b780f14a9cf103f8bca15d2","kind":9734,"pubkey":"5c99b266d2c29ba7e86fcf598ad304ca04e8925f65d9cdc113487f95ac1898a3","sig":"7ff617830f29e07e8fa4ec36daa2061170ca51802652f2d21dda08183dcffe2d62bad107893b0eb04a681bc5ec945ebcc1618c7d827bd05fa1987860fa1d389d","tags":[["p","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],["amount","21000"],["relays","wss://relay.example/x"]]}"""

    /** go-nostr's verdicts, on the raw and the rebuilt text alike. */
    private val verdicts: Map<String, Boolean> =
        mapOf(signed to true, unsigned to false, badSig to false, otherSigner to false, duplicatePubkey to true,
            duplicateRebuiltHere to true) + rebuilt.values.associate { it.first to it.second }

    /**
     * Stands in for the app's verifier with go-nostr's recorded verdicts.
     * Anything not in the table (the malformed cases, built here) passes, so the
     * shape checks are proven on their own.
     */
    private fun verify(json: String) = verdicts[json] ?: true

    private fun parsed(json: String) = Json.parseToJsonElement(json).jsonObject

    private fun request(pubkey: String? = zapper, kind: Int = 9734, p: List<String> = listOf(zapped)): String =
        buildJsonObject {
            put("kind", kind)
            put("content", "")
            put("created_at", 1_799_999_990)
            put("tags", JsonArray((p.map { listOf("p", it) } + listOf(listOf("amount", "21000"))).map { t -> JsonArray(t.map(::JsonPrimitive)) }))
            if (!pubkey.isNullOrEmpty()) put("pubkey", pubkey)
            // A full set of fields, so the request rebuilds and only the shape check
            // under test can turn it away (the table's verifier passes it).
            put("id", "d".repeat(64))
            put("sig", "e".repeat(128))
        }.toString()

    private fun receipt(description: String?, p: List<String> = listOf(zapped), id: String = "c".repeat(64),
                        createdAt: Double = now - 3): JsonObject {
        val tags = p.map { listOf("p", it) } + listOf(listOf("bolt11", "lnbc210n1...")) +
            (description?.let { listOf(listOf("description", it)) } ?: emptyList())
        return buildJsonObject {
            put("id", id)
            put("pubkey", server)
            put("kind", 9735)
            put("created_at", createdAt)
            put("tags", JsonArray(tags.map { t -> JsonArray(t.map(::JsonPrimitive)) }))
        }
    }

    private fun arrival(event: JsonObject, verify: ((String) -> Boolean)? = ::verify) =
        GlobeArcs.arrival(event, nowSeconds = now, verifyZap = verify)

    @Test fun aZapFliesFromTheZapperNotTheServerToThePersonZapped() {
        val arrival = arrival(receipt(signed))
        assertEquals(signedZapper, arrival?.author)
        assertEquals(listOf(zapped), arrival?.targets)
        assertEquals(GlobeArcs.Sort.ZAP, arrival?.sort)
        // The signed request's 21,000 msats strike as a 21-sat zap.
        assertEquals(GlobeZaps.zapStrength(21), arrival!!.strength, 0.0)
        assertEquals(arrival, GlobeZaps.zap(receipt(signed), now, ::verify))
        // The verifier is handed the request as read here, rebuilt: the same text the iPhone hands it.
        var seen: String? = null
        GlobeZaps.zap(receipt(signed), now) { seen = it; true }
        assertEquals(rebuilt.getValue("signed").first, seen)
    }

    @Test fun aRequestWithoutItsProperFieldsIsntVerified() {
        fun with(key: String, value: kotlinx.serialization.json.JsonElement?) = JsonObject(
            parsed(signed).toMutableMap().apply { if (value == null) remove(key) else put(key, value) })
        assertNull(GlobeZaps.canonicalRequest(with("id", JsonPrimitive("x"))))
        assertNull(GlobeZaps.canonicalRequest(with("created_at", JsonPrimitive(1_799_999_990.5))))
        assertNull(GlobeZaps.canonicalRequest(with("created_at", JsonPrimitive("1799999990"))))
        // A whole number written as a float is that integer, rendered plainly: the
        // honest request rebuilds the same either way.
        for (written in listOf("1799999990.0", "1.79999999e9")) {
            val text = signed.replace("\"created_at\":1799999990", "\"created_at\":$written")
            assertNotEquals(signed, text)
            assertEquals(written, rebuilt.getValue("signed").first, GlobeZaps.canonicalRequest(parsed(text)))
        }
        assertNull(GlobeZaps.canonicalRequest(with("sig", null)))
        assertNotNull(GlobeZaps.canonicalRequest(parsed(signed)))
    }

    @Test fun theRebuiltRequestsAreTheOnesTheIPhoneRecorded() {
        for (name in listOf("signed", "badSig", "otherSigner")) {
            val raw = mapOf("signed" to signed, "badSig" to badSig, "otherSigner" to otherSigner).getValue(name)
            assertEquals(name, rebuilt.getValue(name).first, GlobeZaps.canonicalRequest(parsed(raw)))
        }
        // An unsigned request has no sig, and isn't even rebuilt for the check.
        assertNull(parsed(unsigned)["sig"])
        assertNull(GlobeZaps.canonicalRequest(parsed(unsigned)))
        // created_at stays an integer, the way it was signed.
        assertTrue(rebuilt.getValue("signed").first.contains("\"created_at\":1799999990,"))
        // A key given twice: read last-wins here, so it rebuilds as its real signer's request.
        assertEquals(duplicateRebuiltHere, GlobeZaps.canonicalRequest(parsed(duplicatePubkey)))
    }

    @Test fun aZapWhoseRequestIsntSignedByItsZapperDrawsNothing() {
        assertEquals(true, rebuilt.getValue("signed").second)
        for ((why, request) in listOf("unsigned" to unsigned, "garbage signature" to badSig, "signed by someone else" to otherSigner)) {
            assertNull(why, arrival(receipt(request)))
        }
        for (name in listOf("badSig", "otherSigner")) assertEquals(name, false, rebuilt.getValue(name).second)
        // A key given twice never draws the victim: here it draws the one who really signed it.
        val dup = arrival(receipt(duplicatePubkey))
        assertNotEquals(victim, dup?.author)
        assertEquals(attacker, dup?.author)
        // With no verifier at all, a zap draws nothing: the check can't be skipped.
        assertNull(arrival(receipt(signed), verify = null))
        // A verifier that says no (the native library missing fails closed) draws nothing.
        assertNull(arrival(receipt(signed), verify = { false }))
    }

    @Test fun aBrokenReceiptDrawsNothing() {
        val cases = listOf(
            "no request" to receipt(null),
            "request isn't JSON" to receipt("{not json"),
            "request isn't a 9734" to receipt(request(kind = 1)),
            "request has no zapper" to receipt(request(pubkey = "")),
            "request names someone else" to receipt(request(p = listOf(me))),
            "request names two people" to receipt(request(p = listOf(zapped, me))),
            "receipt names two people" to receipt(signed, p = listOf(zapped, me)),
            "zapping yourself" to receipt(request(p = listOf(zapper)), p = listOf(zapper)),
            "bad id" to receipt(signed, id = "x"),
        )
        for ((why, event) in cases) assertNull(why, arrival(event))
        // The control: the same well-formed request, aimed right, does fly.
        assertNotNull(arrival(receipt(request())))
        // An old receipt is a relay catching up, not a zap now.
        assertNull(arrival(receipt(signed, createdAt = now - GlobeArcs.MAX_AGE - 1)))
    }

    @Test fun aBoltStrikesFlashesAndFadesQuickerThanAStar() {
        val board = GlobeArcs.Board()
        board.add(arrival(receipt(signed))!!)
        board.step(0.0, me)
        val line = board.lines[0]
        assertTrue(line.zap)
        assertEquals(signedZapper, line.from)
        assertEquals(zapped, line.to)
        // Across almost at once, full while it flashes, then an afterglow.
        assertEquals(1.0, GlobeArcs.stage(line, GlobeZaps.BOLT_STRIKE).head, 0.0)
        assertEquals(1.0, GlobeArcs.stage(line, GlobeZaps.BOLT_STRIKE + GlobeZaps.BOLT_FLASH).alpha, 0.0)
        val glow = GlobeArcs.stage(line, GlobeZaps.BOLT_STRIKE + GlobeZaps.BOLT_FLASH + GlobeZaps.BOLT_GLOW / 2).alpha
        assertTrue(glow > 0 && glow < 0.5)
        assertTrue(GlobeArcs.isGone(line, GlobeZaps.BOLT_LIFE))
        assertTrue(GlobeZaps.BOLT_LIFE < GlobeArcs.TRAVEL + GlobeArcs.HOLD + GlobeArcs.FADE)
        // Reduce Motion: there at once.
        assertEquals(1.0, GlobeArcs.stage(line, 0.01, reduceMotion = true).head, 0.0)
        // It shares the stars' cap.
        for (n in 0 until GlobeArcs.MAX_LINES + 30) {
            board.add(GlobeArcs.Arrival(String.format("%064x", n + 1), zapper, listOf(zapped), sort = GlobeArcs.Sort.ZAP))
            board.step((n + 1) * 0.01, me)
        }
        assertTrue(board.lines.count { it.retired == null } <= GlobeArcs.MAX_LINES)
    }

    @Test fun theBoltIsJaggedPinnedAtBothEndsAndPlainUnderReduceMotion() {
        val seed = GlobeBolt.seed("zap-id")
        val a = GlobeBolt.offsets(seed, 3, false)
        assertEquals(GlobeBolt.SEGMENTS + 1, a.size)
        assertEquals(0.0, a.first(), 0.0)
        assertEquals(0.0, a.last(), 0.0)
        assertTrue(a.all { abs(it) <= GlobeBolt.REACH })
        assertTrue(a.maxOf { abs(it) } > GlobeBolt.REACH * 0.2)
        // The same frame draws the same bolt; the next frame flickers.
        assertEquals(a, GlobeBolt.offsets(seed, 3, false))
        assertNotEquals(a, GlobeBolt.offsets(seed, 4, false))
        // Its afterglow holds one shape.
        assertEquals(GlobeBolt.frame(1.0, false), GlobeBolt.frame(1.5, false))
        assertTrue(GlobeBolt.offsets(seed, 3, true).all { it == 0.0 })
        val fork = GlobeBolt.fork(seed)
        assertTrue(fork.from in 1 until GlobeBolt.SEGMENTS)
    }

    @Test fun theSeedIsFnv1aLikeTheIPhones() {
        // FNV-1a 64 of "a" is 0xaf63dc4c8601ec8c; of "" the offset basis.
        assertEquals(0xaf63dc4c8601ec8cUL.toLong(), GlobeBolt.seed("a"))
        assertEquals(0xcbf29ce484222325UL.toLong(), GlobeBolt.seed(""))
    }

    @Test fun theZapFilterKeepsTheRequestUnderTheSizeCap() {
        val filter = buildJsonObject {
            put("kinds", JsonArray(listOf(JsonPrimitive(GlobeArcs.ZAP_KIND))))
            put("since", 1)
        }
        val requests = GlobeArcs.requests(listOf(filter), "arcs-x")
        assertEquals(1, requests.size)
        assertTrue(requests[0].toByteArray().size < GlobeArcs.MAX_REQUEST_BYTES)
    }

    @Test fun zapsSwitchedOffAreNeitherAskedForNorFlown() {
        val show = GlobeLive.Show(zaps = false)
        assertTrue(!show.allows(GlobeArcs.Sort.ZAP))
        val kinds = GlobeStorm.storm(setOf(GlobeArcs.Ring.GLOBAL), show, emptyList(), 0).single()["kinds"] as JsonArray
        assertTrue(kinds.none { (it as JsonPrimitive).content == GlobeArcs.ZAP_KIND.toString() })
    }
}
