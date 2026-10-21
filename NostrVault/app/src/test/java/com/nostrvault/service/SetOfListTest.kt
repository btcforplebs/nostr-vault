package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Test

class SetOfListTest {
    @Test
    fun `the same list gives the same set without rebuilding`() {
        val sets = SetOfList<String>()
        val list = listOf("a", "b")
        assertSame(sets.of(list), sets.of(list))
    }

    @Test
    fun `a new list gives its own set`() {
        val sets = SetOfList<String>()
        val first = sets.of(listOf("a"))
        val second = sets.of(listOf("a", "b"))
        assertNotSame(first, second)
        assertEquals(setOf("a", "b"), second)
        assertEquals(setOf("a"), first)
    }

    @Test
    fun `the empty start is empty`() {
        assertEquals(emptySet<String>(), SetOfList<String>().of(emptyList()))
    }
}
