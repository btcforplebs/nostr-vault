package com.nostrvault.shareportal

import com.nostrvault.shareportal.ShareFixtures.str
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Lane D's pay target finder, read from the same fixture as the Swift tests (pay-target-cases.json). */
class PayShareTargetTest {
    private val fixture = ShareFixtures.load("pay-target-cases.json")

    private fun target(o: JsonObject?): PayShareTarget? {
        o ?: return null
        val kind = PayShareTarget.Kind.entries.first { it.raw == o.str("kind") }
        return PayShareTarget(o.str("token")!!, kind, o.str("npub"))
    }

    @Test fun findMatchesSharedFixtures() {
        val cases = fixture["cases"]!!.jsonArray
        var found = 0
        val failures = cases.mapNotNull { c ->
            val o = c.jsonObject
            val i = o["input"]!!.jsonObject
            val got = PayShareTarget.find(i.str("url"), i.str("text"), i.str("selection"))
            val want = target(o["expect"].takeUnless { it is JsonNull } as? JsonObject)
            if (want != null) found++
            if (got == want) null else "${o.str("name")}: want $want, got $got"
        }
        assertEquals(failures.joinToString("\n"), emptyList<String>(), failures)
        // Both outcomes are exercised, so a finder that always (or never) finds cannot pass.
        assertTrue(found > 5 && cases.size - found > 3)
    }

    /** Every input the finder accepts is one the classifier offers Pay for first. */
    @Test fun finderAgreesWithClassifier() {
        fixture["cases"]!!.jsonArray.map { it.jsonObject }.filter { it["expect"] is JsonObject }.forEach { o ->
            val input = ShareFixtures.input(o["input"]!!.jsonObject)
            assertEquals(o.str("name"), ShareAction.PAY, ShareClassifier.classify(input).first())
        }
    }

    @Test fun zapMatchesSharedFixtures() {
        val cases = fixture["zap"]!!.jsonArray
        assertTrue(cases.any { (it.jsonObject["expect"] as JsonPrimitive).booleanOrNull == true })
        cases.forEach { c ->
            val o = c.jsonObject
            val t = target(o["target"]!!.jsonObject)!!
            val lud16 = o.str("lud16")
            assertEquals(o.str("name"), (o["expect"] as JsonPrimitive).booleanOrNull, PayShareTarget.canZap(t, lud16))
        }
    }
}
