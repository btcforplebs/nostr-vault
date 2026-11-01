package com.nostrvault.relay

import org.junit.Assert.assertEquals
import org.junit.Test

class GoRuntimeEnvTest {

    @Test
    fun `sets the three Go values, memory limit sized to the phone`() {
        val values = GoRuntimeEnv.values(8L shl 30).toMap()
        assertEquals(setOf("GODEBUG", "GOMEMLIMIT", "GOGC"), values.keys)
        assertEquals("asyncpreemptoff=1,cgocheck=0,madvdontneed=1", values["GODEBUG"])
        assertEquals("1024MiB", values["GOMEMLIMIT"])
        assertEquals("50", values["GOGC"])
    }

    @Test
    fun `second call sets nothing`() {
        val set = mutableListOf<String>()
        val applier = GoRuntimeEnv.Applier { k, _ -> set += k }
        applier.ensure()
        assertEquals(listOf("GODEBUG", "GOMEMLIMIT", "GOGC"), set)
        applier.ensure()
        assertEquals(3, set.size)
    }
}
