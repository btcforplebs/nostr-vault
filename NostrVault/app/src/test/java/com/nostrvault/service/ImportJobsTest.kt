package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The engine's import jobs (Ted #1763, PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md "Engine API"). */
class ImportJobsTest {
    private val sample = """
        {"account":"ab","start_date":"2023-01-01","future":1,"jobs":[
          {"name":"setup","status":"partial","started_at":100,"ended_at":111,"reason":"relay_silent","stored":812,
           "unread":[{"relay":"wss://nostr.wine","from":"2023-01-01","to":"2026-11-05","why":"not_read_yet"}],"est_seconds":11},
          {"name":"replies","status":"never","est_seconds":180},
          {"name":"older_relays","status":"running","stored":40,"reason":"will_resume"},
          {"name":"wider_network","status":"done","ended_at":1000,"stored":5000,"est_seconds":90}
        ]}
    """.trimIndent()

    @Test
    fun `the job list parses and ignores keys it doesn't know`() {
        val jobs = ImportJobs.parse(sample)!!
        assertEquals("2023-01-01", jobs.startDate)
        assertEquals(listOf("replies", "older_relays", "wider_network"), jobs.stillToBringIn.map { it.name })
        assertEquals("nostr.wine: 2023-01-01 to 2026-11-05 (not read yet)", ImportJobs.unreadLines(jobs.job("setup")!!).single())
        assertNull(ImportJobs.parse("not json"))
        assertNull(ImportJobs.parse(""))
    }

    @Test
    fun `setup lets you in on done or partial, never on the rest`() {
        val setup = ImportJobs.parse(sample)!!.job("setup")!!
        assertTrue(setup.letsIn)
        for (s in listOf("never", "running", "failed", "cancelled")) assertFalse(s, setup.copy(status = s).letsIn)
        assertTrue(setup.copy(status = "done").letsIn)
    }

    @Test
    fun `the IMPORT_JOB line reads with its log prefix`() {
        assertEquals("setup" to "done", ImportJobs.logLine("2026/11/05 14:00:01 IMPORT_JOB name=setup status=done stored=812 unread=0 new=1"))
        assertNull(ImportJobs.logLine("IMPORT_RESULT status=complete"))
        assertNull(ImportJobs.logLine("IMPORT_JOB status=done"))
    }

    @Test
    fun `a partial row never reads as done, and a cut one says it picks up`() {
        val jobs = ImportJobs.parse(sample)!!
        val now = 1_200L
        assertTrue(ImportJobs.statusLine(jobs.job("setup")!!, now).startsWith("Not all read"))
        assertTrue(ImportJobs.statusLine(jobs.job("wider_network")!!, now).startsWith("Done"))
        assertEquals("Picks up where it stopped", ImportJobs.statusLine(jobs.job("older_relays")!!, now))
        assertEquals("Not run yet · about 3 min", ImportJobs.statusLine(jobs.job("replies")!!, now))
    }

    @Test
    fun `a refused run says why`() {
        assertNull(ImportJobs.runRefusal(ImportJobs.RUN_STARTED))
        assertEquals("Another one is running. One at a time.", ImportJobs.runRefusal(ImportJobs.RUN_BUSY))
        assertEquals("Your vault isn't running. Start it, then try again.", ImportJobs.runRefusal(ImportJobs.RUN_RELAY_NOT_RUNNING))
    }

    @Test
    fun `an unread line shows the host, never a path with a secret in it`() {
        val job = ImportJobs.Job(name = "older_relays", unread = listOf(ImportJobs.Unread(relay = "ws://127.0.0.1:4100/s3cret", from = "2020-11-01", to = "2026-11-05", why = "not_read_yet")))
        assertEquals("127.0.0.1:4100: 2020-11-01 to 2026-11-05 (not read yet)", ImportJobs.unreadLines(job).single())
    }

    @Test
    fun `the other vault's address closes once nothing is left to read from it`() {
        val url = "ws://127.0.0.1:4100/s3cret"
        fun jobs(older: String, unread: String?) = ImportJobs.parse("""
            {"jobs":[{"name":"setup","status":"partial"},
              {"name":"older_relays","status":"$older","unread":[${unread?.let { "{\"relay\":\"$it\",\"why\":\"not_read_yet\"}" } ?: ""}]}]}
        """.trimIndent())!!
        assertTrue(FirstRunImport.stillToRead(jobs("partial", url), url))
        assertTrue(FirstRunImport.stillToRead(jobs("partial", "$url/"), url))
        assertTrue(FirstRunImport.stillToRead(jobs("running", null), url))
        assertFalse(FirstRunImport.stillToRead(jobs("done", null), url))
        assertFalse(FirstRunImport.stillToRead(jobs("partial", "wss://nostr.wine"), url))
    }
}
