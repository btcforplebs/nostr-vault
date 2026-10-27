package com.nostrvault.util

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The same invoices as iOS NoteInvoicesTests (zeroed signature, valid checksum). */
class NoteInvoicesTest {
    /** 2,100 sats, "Coffee for Logen", made 2025-10-27 16:00Z, 1 h expiry. */
    private val coffee = "lnbc21u1p50l9cqpp5qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0sdq6gdhkven9v5sxvmmjypxx7em9dcxqrrssqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsz8ap9"
    /** Amountless, "Tip jar", same time, no `x` field. */
    private val tipJar = "lnbc1p50l9cqpp5qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0sdqv235hqgr2v9eqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq7aq7d0"
    /** 150 sats, "old one", made 2017-07-14, 60 s expiry. */
    private val stale = "lnbc1500n1pvkstcqpp5qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0sdqvdakxggr0dejsxqzpuqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqmtms8k"
    /** 500 sats, "Sim card ☕", 1 day expiry: a multi-byte memo. */
    private val cup = "lnbc5000n1p4wpj5qpp5qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0sdq52d5k6grrv9exgg8znz2sxqyz5vqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqtdpp0"

    private val made = 1_761_580_800L

    @Test fun `details read amount, memo and expiry`() {
        val d = Bolt11Details.read(coffee)!!
        assertEquals(Bolt11Amount.Sats(2_100L), d.amount)
        assertEquals("Coffee for Logen", d.memo)
        assertEquals(made, d.createdAt)
        assertEquals(made + 3600, d.expiresAt)
        assertFalse(d.isExpired(made + 3599))
        assertTrue(d.isExpired(made + 3600))
    }

    @Test fun `an old invoice is expired`() {
        val d = Bolt11Details.read(stale)!!
        assertEquals(Bolt11Amount.Sats(150L), d.amount)
        assertEquals(60L, d.expiresAt - d.createdAt)
        assertTrue(d.isExpired(made))
    }

    @Test fun `no amount and the default expiry`() {
        val d = Bolt11Details.read(tipJar)!!
        assertEquals(Bolt11Amount.Unspecified, d.amount)
        assertEquals("Tip jar", d.memo)
        assertEquals(made + Bolt11Details.DEFAULT_EXPIRY, d.expiresAt)
    }

    @Test fun `upper case invoices with a lightning prefix`() {
        assertEquals(Bolt11Details.read(coffee), Bolt11Details.read(coffee.uppercase()))
        val found = NoteInvoices.find("Pay me: LIGHTNING:${coffee.uppercase()} thanks")
        assertEquals(listOf(coffee), found.map { it.invoice })
        assertEquals("LIGHTNING:${coffee.uppercase()}", found.first().raw)
    }

    @Test fun `multi-byte memo`() {
        assertEquals("Sim card ☕", Bolt11Details.read(cup)?.memo)
        assertEquals(Bolt11Amount.Sats(500L), Bolt11Details.read(cup)?.amount)
    }

    @Test fun `found in note text, each once, and cut out of it`() {
        val note = "Coffee fund ⚡\n\nlightning:$coffee\n\nor $tipJar\nagain $coffee"
        val found = NoteInvoices.find(note)
        assertEquals(listOf(coffee, tipJar), found.map { it.invoice })
        assertEquals("Coffee fund ⚡    or  again", NoteInvoices.strip(found, note).trim().replace("\n", " "))
    }

    @Test fun `the text left once invoices are cards has no gap where they were`() {
        val note = "Coffee fund\n\nlightning:$coffee\n\nor $tipJar\nthanks"
        assertEquals("Coffee fund\n\nor\nthanks", NoteInvoices.textWithout(NoteInvoices.find(note), note))
        assertEquals("no invoice \n\n\n here", NoteInvoices.textWithout(emptyList(), "no invoice \n\n\n here"))
    }

    @Test fun `lookalikes stay text`() {
        assertTrue(NoteInvoices.find("lnbc21u1pvjluez is short").isEmpty())
        assertTrue(NoteInvoices.find("x$coffee").isEmpty())
        assertNull(Bolt11Details.read("lnbc21u1" + "b".repeat(130)))
        assertTrue(NoteInvoices.find("no lightning here").isEmpty())
        assertEquals("plain text", NoteInvoices.strip(emptyList(), "plain text"))
    }
}
