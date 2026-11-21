package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HeapCapTest {
    private val mb = 1L shl 20

    @Test fun `an ordinary heap keeps the usual caps`() {
        assertEquals(100 * mb, HeapCap.of(100 * mb, heapMax = 512 * mb))
        assertEquals(50 * mb, HeapCap.of(50 * mb, heapMax = 401 * mb))
        assertNull(HeapCap.tooBigHere(100 * mb, heapMax = 512 * mb))
    }

    @Test fun `a small heap allows a sixth of itself`() {
        assertEquals(64 * mb, HeapCap.of(100 * mb, heapMax = 384 * mb))
        assertEquals(256 * mb / 6, HeapCap.of(100 * mb, heapMax = 256 * mb))
        assertEquals(32 * mb, HeapCap.of(50 * mb, heapMax = 192 * mb))
        assertEquals("Too big for this phone's memory (at most 32 MB here).", HeapCap.tooBigHere(100 * mb, heapMax = 192 * mb))
    }

    @Test fun `a small heap never raises a cap that is already lower`() {
        assertEquals(10 * mb, HeapCap.of(10 * mb, heapMax = 256 * mb))
        assertNull(HeapCap.tooBigHere(10 * mb, heapMax = 256 * mb))
    }

    @Test fun `a heap that can't be read keeps the usual caps`() {
        assertEquals(100 * mb, HeapCap.of(100 * mb, heapMax = 0))
    }
}
