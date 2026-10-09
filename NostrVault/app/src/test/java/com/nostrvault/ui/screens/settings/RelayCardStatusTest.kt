package com.nostrvault.ui.screens.settings

import com.nostrvault.relay.HavenConfig
import com.nostrvault.relay.RelayForegroundService.RelayStatus
import org.junit.Assert.assertEquals
import org.junit.Test

class RelayCardStatusTest {
    @Test fun statusWords() {
        assertEquals(RelayCardStatus.RUNNING, RelayCardStatus.of(RelayStatus.RUNNING, external = false))
        assertEquals(RelayCardStatus.STARTING, RelayCardStatus.of(RelayStatus.BOOTING, external = false))
        assertEquals(RelayCardStatus.STARTING, RelayCardStatus.of(RelayStatus.IMPORTING, external = false))
        assertEquals(RelayCardStatus.STOPPED, RelayCardStatus.of(RelayStatus.OFFLINE, external = false))
        // Another app's relay: no Running/Stopped claim, and no Start button.
        assertEquals(RelayCardStatus.EXTERNAL, RelayCardStatus.of(RelayStatus.OFFLINE, external = true))
    }

    @Test fun addressIsLoopbackForTheEmbeddedRelay() {
        assertEquals("ws://127.0.0.1:4000", RelayCardStatus.address(HavenConfig(relayPort = 4000)))
    }
}
