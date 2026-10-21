package com.nostrvault.ui.screens.profile

import com.nostrvault.data.model.FeedProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfilePhotoUploadTest {
    @Test fun smallPhotoKeepsItsSize() {
        assertEquals(800 to 600, ProfilePhotoSizing.scaled(800, 600, 1024))
    }

    @Test fun largePhotoShrinksToTheLongEdge() {
        assertEquals(1024 to 768, ProfilePhotoSizing.scaled(4032, 3024, 1024))
        assertEquals(768 to 1024, ProfilePhotoSizing.scaled(3024, 4032, 1024))
    }

    @Test fun bannerKeepsMoreThanPicture() {
        assertEquals(2400 to 800, ProfilePhotoSizing.scaled(6000, 2000, ProfilePhotoTarget.BANNER.longEdge))
        assertEquals(1024 to 341, ProfilePhotoSizing.scaled(6000, 2000, ProfilePhotoTarget.PICTURE.longEdge))
    }

    @Test fun extremeAspectNeverReachesZero() {
        assertEquals(1024 to 1, ProfilePhotoSizing.scaled(100_000, 10, 1024))
    }

    @Test fun sampleSizeLeavesAtLeastTheLongEdge() {
        assertEquals(1, ProfilePhotoSizing.sampleSize(1500, 1000, 1024))
        assertEquals(2, ProfilePhotoSizing.sampleSize(2048, 1536, 1024))
        assertEquals(4, ProfilePhotoSizing.sampleSize(8000, 6000, 1024))
        val sample = ProfilePhotoSizing.sampleSize(8000, 6000, 1024)
        assertTrue(8000 / sample >= 1024)
    }

    @Test fun noProfileIsAwaitedUntilTheCap() {
        assertTrue(ProfileMetadataWait.awaiting(null, waitOver = false))
        assertFalse(ProfileMetadataWait.awaiting(null, waitOver = true))
    }

    @Test fun anEmptyProfileIsStillAwaited() {
        assertTrue(ProfileMetadataWait.awaiting(FeedProfile(pubkey = "ab"), waitOver = false))
    }

    @Test fun anyMetadataEndsTheWait() {
        assertFalse(ProfileMetadataWait.awaiting(FeedProfile(pubkey = "ab", name = "sat"), waitOver = false))
        assertFalse(ProfileMetadataWait.awaiting(FeedProfile(pubkey = "ab", lud16 = "a@b.c"), waitOver = false))
    }
}
