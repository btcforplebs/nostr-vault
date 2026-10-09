package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NostrServiceCountTest {
    @Test
    fun `reads the count as an integer, a float or a string`() {
        assertEquals(1234, NostrService.countFrom("""["COUNT","c",{"count":1234}]"""))
        assertEquals(56, NostrService.countFrom("""["COUNT","c",{"count":56.0,"approximate":true}]"""))
        assertEquals(7, NostrService.countFrom("""["COUNT","c",{"count":"7"}]"""))
    }

    @Test
    fun `anything else is no count`() {
        assertNull(NostrService.countFrom("""["CLOSED","c","unsupported: COUNT"]"""))
        assertNull(NostrService.countFrom("""["COUNT","c",{}]"""))
        assertNull(NostrService.countFrom("""["COUNT","c",{"count":-1}]"""))
        assertNull(NostrService.countFrom("""["NOTICE","bad"]"""))
        assertNull(NostrService.countFrom("not json"))
    }
}
