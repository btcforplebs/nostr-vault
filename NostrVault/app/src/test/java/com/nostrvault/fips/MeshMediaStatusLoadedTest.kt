package com.nostrvault.fips

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

/** A photo that loads drops "Couldn't reach the owner's vault", whichever copy drew it. */
class MeshMediaStatusLoadedTest {
    private val sha = "703d478c8fc229c893638167bd705239b07a9e8ae1dcdfd3312c05ab424c3bbb"
    private val url = "http://127.0.0.1:4869/$sha.jpg"

    @After fun reset() = MeshMediaStatus.clear(sha)

    @Test
    fun `loading the same url clears it`() {
        MeshMediaStatus.set(sha, MeshMediaPhase.Unreached)
        MeshMediaStatus.loaded(url)
        assertNull(MeshMediaStatus.phaseFor(MeshMediaStatus.phases.value, url))
    }

    @Test
    fun `loading this vault's own file clears the url's line`() {
        MeshMediaStatus.set(sha, MeshMediaPhase.Unreached)
        MeshMediaStatus.loaded(File("/data/user/0/app/files/relay_data/blossom/$sha.jpeg"))
        assertNull(MeshMediaStatus.phaseFor(MeshMediaStatus.phases.value, url))
    }

    @Test
    fun `another photo loading leaves it`() {
        MeshMediaStatus.set(sha, MeshMediaPhase.Unreached)
        MeshMediaStatus.loaded("https://example.com/${"a".repeat(64)}.jpg")
        assertEquals(MeshMediaPhase.Unreached, MeshMediaStatus.phaseFor(MeshMediaStatus.phases.value, url))
    }
}
