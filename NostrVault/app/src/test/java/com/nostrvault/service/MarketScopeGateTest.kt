package com.nostrvault.service

import com.nostrvault.data.model.ReelsScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Marketplace opens on Following and asks before Global (Logen 2026-10-22). */
class MarketScopeGateTest {
    @Test
    fun `it opens on following`() {
        assertEquals(ReelsScope.FOLLOWING, MarketScopeGate.OPENS_ON)
    }

    @Test
    fun `global waits for the warning and following does not`() {
        assertEquals(MarketScopeGate.Action.WARN, MarketScopeGate.request(ReelsScope.GLOBAL, ReelsScope.FOLLOWING))
        assertEquals(MarketScopeGate.Action.SWITCH, MarketScopeGate.request(ReelsScope.FOLLOWING, ReelsScope.GLOBAL))
        assertEquals(MarketScopeGate.Action.NONE, MarketScopeGate.request(ReelsScope.GLOBAL, ReelsScope.GLOBAL))
        assertEquals(MarketScopeGate.Action.NONE, MarketScopeGate.request(ReelsScope.FOLLOWING, ReelsScope.FOLLOWING))
    }

    /**
     * Wiring, source-level (the service needs relays and Compose a device): the service starts on
     * the gate's scope and every setScope goes through it, and the screen shows the warning.
     */
    @Test
    fun `the service and the screen use it`() {
        val service = File("src/main/java/com/nostrvault/service/MarketplaceFeedService.kt").readText()
        assertTrue(service.contains("MutableStateFlow(MarketScopeGate.OPENS_ON)"))
        val setScope = service.substringAfter("fun setScope(newScope: ReelsScope) {").substringBefore("\n    }")
        assertTrue(setScope.contains("MarketScopeGate.request(newScope, _scope.value)"))
        assertTrue(setScope.contains("Action.WARN -> _globalWarningPending.value = true"))
        val screen = File("src/main/java/com/nostrvault/ui/screens/feed/MarketplaceScreen.kt").readText()
        assertTrue(screen.contains("if (globalWarningPending) MarketplaceGlobalWarning(onConfirmGlobal, onCancelGlobal)"))
        val feed = File("src/main/java/com/nostrvault/ui/screens/feed/FeedScreen.kt").readText()
        assertTrue(feed.contains("globalWarningPending = marketGlobalWarning"))
    }
}
