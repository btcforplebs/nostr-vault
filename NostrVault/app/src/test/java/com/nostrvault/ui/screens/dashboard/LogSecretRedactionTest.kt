package com.nostrvault.ui.screens.dashboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** The Logs screen shows and copies lines with secrets replaced (Android review K4). */
class LogSecretRedactionTest {

    @Test fun aBunkerSecretIsRedacted() {
        val line = """NIP46ConnectC: invalid bunker URL error="parse \"bunker://ab\u007f?relay=wss://r.example&secret=hunter2\": invalid control character""""
        val shown = redactLogSecrets(line)
        assertFalse(shown.contains("hunter2"))
        assertEquals(true, shown.contains("secret=[redacted]"))
        assertEquals(true, shown.contains("relay=wss://r.example"))
    }

    @Test fun anNwcSecretAndAnNsecAreRedacted() {
        val shown = redactLogSecrets(
            "nostr+walletconnect://abc?relay=wss://r&secret=0123abcd&lud16=x key nsec1v4jzkcm9wd5kz6m0vdkx2ar9 end"
        )
        assertFalse(shown.contains("0123abcd"))
        assertFalse(shown.contains("v4jzkcm9"))
        assertEquals(true, shown.contains("&lud16=x"))
        assertEquals(true, shown.endsWith("nsec1[redacted] end"))
    }

    @Test fun anySecretValueIsRedactedAndPlainLinesAreKept() {
        val line = "connect RPC (secret=12 chars)"
        assertEquals("connect RPC (secret=[redacted] chars)", redactLogSecrets(line))
        assertEquals("plain line", redactLogSecrets("plain line"))
    }
}
