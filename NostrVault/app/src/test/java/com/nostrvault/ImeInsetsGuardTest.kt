package com.nostrvault

import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The app is edge-to-edge, so the window does not resize for the keyboard.
 * The one place that lifts every screen above it is the Box around the nav
 * host in MainActivity; losing it puts the keyboard back over DM, settings
 * and setup inputs. Source-level because the Compose tree needs a device.
 */
class ImeInsetsGuardTest {
    @Test
    fun navHostIsWrappedInImePadding() {
        val src = File("src/main/java/com/nostrvault/MainActivity.kt").readText()
        val host = src.indexOf("NostrVaultNavHost(")
        assertTrue("NostrVaultNavHost call not found", host > 0)
        val wrapper = src.lastIndexOf("Box(", host)
        assertTrue("no Box before the nav host", wrapper > 0)
        assertTrue(
            "nav host must sit inside Box(...imePadding())",
            src.substring(wrapper, host).contains("imePadding()"),
        )
    }
}
