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
            MyWebDesktopVaultWords.detail(pulling = true, failed = true, lastAt = now, nowS = now))
    }

    @Test fun aDesktopNeverCopiedFromStillReads() {
        // Rank only (MeshRankPull): no first copy needed, so no "copy first" line.
        assertEquals("Read over the mesh",
            MyWebDesktopVaultWords.detail(pulling = false, failed = false, lastAt = null, nowS = now))
    }

    @Test fun aFailedPullSaysTryAgain() {
        assertEquals("Couldn't reach it over the mesh. Try again",
            MyWebDesktopVaultWords.detail(pulling = false, failed = true, lastAt = now - 60, nowS = now))
    }

    @Test fun lastReadSaysHowLongAgo() {
        assertEquals("Read over the mesh 5 min ago",
            MyWebDesktopVaultWords.detail(pulling = false, failed = false, lastAt = now - 300, nowS = now))
    }
}
