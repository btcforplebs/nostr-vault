package com.nostrvault.ui.components

import com.nostrvault.data.model.TrustMapOuter
import org.junit.Assert.assertEquals
import org.junit.Test

/** My Web › Desktop Vault's words, as iOS `MyWebDesktopVaultSection` says them. */
class MyWebDesktopVaultWordsTest {
    private val now = 1_800_000_000L

    @Test fun titleFollowsTheRankSource() {
        assertEquals("Found by your desktop Vault", MyWebDesktopVaultWords.title(TrustMapOuter.Source.RANKED))
        assertEquals("Your desktop Vault hasn't sent its ranking yet", MyWebDesktopVaultWords.title(TrustMapOuter.Source.WAITING))
    }

    @Test fun pullingWinsOverEverything() {
        assertEquals("Pulling the ranking over the mesh…",
            MyWebDesktopVaultWords.detail(hasDesktop = true, pulling = true, canPull = true, failed = true, lastAt = now, nowS = now))
    }

    @Test fun aDesktopNeverCopiedFromCannotPull() {
        assertEquals("Copy your vault from it first, in Settings › Your Devices",
            MyWebDesktopVaultWords.detail(hasDesktop = true, pulling = false, canPull = false, failed = false, lastAt = null, nowS = now))
    }

    @Test fun aFailedPullSaysTryAgain() {
        assertEquals("Couldn't reach it over the mesh. Try again",
            MyWebDesktopVaultWords.detail(hasDesktop = true, pulling = false, canPull = true, failed = true, lastAt = now - 60, nowS = now))
    }

    @Test fun lastReadSaysHowLongAgo() {
        assertEquals("Read over the mesh 5 min ago",
            MyWebDesktopVaultWords.detail(hasDesktop = true, pulling = false, canPull = true, failed = false, lastAt = now - 300, nowS = now))
    }
}
