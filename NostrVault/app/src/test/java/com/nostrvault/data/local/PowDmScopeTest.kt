package com.nostrvault.data.local

import android.content.Context
import android.content.SharedPreferences
import io.mockk.every
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Proof of work is only mined in local signing, which a NIP-17 message never
 * reaches (its rumor is unsigned; the seal and wrap are not mined). So the DM
 * setting covers old-style kind 4 messages and nothing else.
 */
class PowDmScopeTest {
    private fun prefs(): PowPreferences {
        val shared = mockk<SharedPreferences>()
        every { shared.getBoolean(any(), any()) } answers { secondArg() }
        every { shared.getInt(any(), any()) } answers { secondArg() }
        val context = mockk<Context>()
        every { context.getSharedPreferences(any(), any()) } returns shared
        return PowPreferences(context)
    }

    @Test fun `the DM setting mines kind 4 only`() {
        val pow = prefs()
        assertEquals(12, pow.difficultyForKind(4))
        assertEquals(0, pow.difficultyForKind(14))
    }
}
