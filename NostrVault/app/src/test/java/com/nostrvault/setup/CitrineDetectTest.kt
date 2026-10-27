package com.nostrvault.setup

import android.content.pm.PackageManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CitrineDetectTest {

    @Test
    fun `an installed Citrine is found by its package name`() {
        var asked: String? = null
        assertTrue(CitrineDetect.isInstalled { asked = it; Any() })
        assertEquals("com.greenart7c3.citrine", asked)
    }

    @Test
    fun `a missing Citrine is not found`() {
        assertFalse(CitrineDetect.isInstalled { throw PackageManager.NameNotFoundException(it) })
    }

    @Test
    fun `a package manager that fails counts as not found`() {
        assertFalse(CitrineDetect.isInstalled { throw SecurityException("no") })
    }
}
