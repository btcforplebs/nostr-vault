package com.nostrvault.ui.screens.profile

import com.nostrvault.data.local.ProfileRepository
import com.nostrvault.data.model.FeedProfile
import com.nostrvault.data.model.parseProfileMetadata
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Profile banners (iOS #321): read from kind 0, sized, and the wash's tint. */
class ProfileBannerTest {
    @Test
    fun kind0BannerIsRead() {
        val content = """{"name":"a","picture":"https://p/a.jpg","banner":"https://p/b.jpg"}"""
        val (profile, changed) = ProfileRepository.parseMetadataContent(content, "pk", null)!!
        assertEquals("https://p/b.jpg", profile.bannerURL)
        assertTrue(changed)
        assertEquals("https://p/b.jpg", parseProfileMetadata("pk", content)?.bannerURL)
    }

    @Test
    fun aNewBannerAloneIsAChange() {
        val existing = FeedProfile(pubkey = "pk", name = "a", bannerURL = "https://p/old.jpg")
        val (profile, changed) = ProfileRepository.parseMetadataContent(
            """{"name":"a","banner":"https://p/new.jpg"}""", "pk", existing,
        )!!
        assertEquals("https://p/new.jpg", profile.bannerURL)
        assertTrue(changed)
    }

    @Test
    fun bannerIsAThirdOfTheWidthWithinBounds() {
        assertEquals(130f, ProfileBannerStyle.heightDp(true, 390f), 0.01f)
        assertEquals(110f, ProfileBannerStyle.heightDp(true, 300f), 0.01f)
        assertEquals(210f, ProfileBannerStyle.heightDp(true, 900f), 0.01f)
        assertEquals(64f, ProfileBannerStyle.heightDp(false, 390f), 0.01f)
    }

    @Test
    fun grayPictureHasNoTint() {
        assertNull(ProfileBannerStyle.washHsv(0.4f, 0.4f, 0.42f))
        assertNull(ProfileBannerStyle.washHsv(0f, 0f, 0f))
    }

    @Test
    fun mutedColorKeepsItsHueWithMoreColorAndLight() {
        val hsv = ProfileBannerStyle.washHsv(0.3f, 0.1f, 0.1f)
        assertNotNull(hsv)
        assertEquals(0f, hsv!![0], 0.5f)
        assertTrue(hsv[1] in 0.45f..0.8f)
        assertEquals(0.5f, hsv[2], 0.001f)
        val blue = ProfileBannerStyle.washHsv(0.1f, 0.2f, 0.9f)!!
        assertEquals(232.5f, blue[0], 0.5f)
        assertEquals(0.75f, blue[2], 0.001f)
    }

    @Test
    fun fallbackHueIsStablePerPubkey() {
        assertEquals(ProfileBannerStyle.fallbackHue("abc"), ProfileBannerStyle.fallbackHue("axyz"))
        assertEquals(('a'.code % 360).toFloat(), ProfileBannerStyle.fallbackHue("abc"))
    }
}
