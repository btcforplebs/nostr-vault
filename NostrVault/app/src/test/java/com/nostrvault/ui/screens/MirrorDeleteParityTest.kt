package com.nostrvault.ui.screens

import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.BlossomService
import com.nostrvault.service.DELETE_NO_MIRRORS_MESSAGE
import com.nostrvault.ui.components.FeedMediaMirrorViewModel
import com.nostrvault.ui.notification.NotificationManager
import com.nostrvault.ui.screens.profile.profileDeleteItem
import com.nostrvault.ui.screens.settings.fipsmesh.PHOTOS_ROUTE_LINE
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Android "Delete from media servers" / "Delete everywhere" against iOS on master
 * (RESEARCH/NV_MIRROR_DELETE_ANDROID_VS_IOS_2026_11_05.md, items 1, 3, 4, 5, 7) and the
 * "Photos go to" picker replaced by one line. Item 2 and 8: BlossomDeleteReportTest.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MirrorDeleteParityTest {

    private val sha = "c".repeat(64)

    @Before fun setUp() = Dispatchers.setMain(UnconfinedTestDispatcher())
    @After fun tearDown() = Dispatchers.resetMain()

    // #1: the profile grid deleted with an empty URL, so the photo's own server was never asked.
    @Test
    fun `a profile tile's delete asks the server the photo is on`() {
        val url = "https://cdn.elsewhere.example/$sha.jpg"
        val item = profileDeleteItem(sha, url)
        assertEquals(url, item.displayUrl)
        val targets = HavenConfig().blossomDeleteTargets(emptyList(), item.displayUrl, includeHomeVault = false)
        assertEquals(listOf("https://cdn.elsewhere.example"), targets)
    }

    // #3: an http mirror on a public host was dropped by "Delete from media servers", unreported.
    @Test
    fun `a plain http public mirror is deleted over https, a home one is not a target`() {
        val config = HavenConfig(blossomMirrors = listOf("http://media.example.com", "http://192.168.1.20:3355"))
        assertEquals(listOf("https://media.example.com"), config.blossomDeleteTargets(emptyList(), null, includeHomeVault = false))
        // Delete everywhere keeps the home-network vault on http.
        assertTrue("http://192.168.1.20:3355" in config.blossomDeleteTargets(emptyList(), null, includeHomeVault = true))
    }

    private val notifications = mockk<NotificationManager>(relaxed = true)

    private fun blossom(report: BlossomService.MirrorDeleteResult) = mockk<BlossomService>(relaxed = true).also {
        coEvery { it.deleteFromServers(any(), any(), any(), any()) } returns report
        coEvery { it.deleteFromLocal(any()) } returns true
    }

    private fun galleryViewer(blossom: BlossomService) =
        MediaViewerViewModel(mockk(relaxed = true), notifications, blossom, mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true))

    private fun feedViewer(blossom: BlossomService) =
        FeedMediaMirrorViewModel(blossom, mockk(relaxed = true), mockk(relaxed = true), mockk(relaxed = true), notifications, mockk(relaxed = true))

    private val item = profileDeleteItem(sha, "https://cdn.elsewhere.example/$sha.jpg")

    // #4: the feed viewer showed "No mirrors to delete from" as a success, the gallery as an error.
    @Test
    fun `no mirrors is an error in the feed viewer too`() {
        feedViewer(blossom(BlossomService.MirrorDeleteResult()))
            .delete(item.displayUrl, DeleteScope.MIRRORS, deletePosts = false, onDone = {}, onAllGone = {})
        verify(timeout = 2_000) { notifications.showError(DELETE_NO_MIRRORS_MESSAGE, any(), any()) }
        verify(exactly = 0) { notifications.showToast(DELETE_NO_MIRRORS_MESSAGE, any()) }
    }

    @Test
    fun `no mirrors is an error in the gallery viewer`() {
        galleryViewer(blossom(BlossomService.MirrorDeleteResult())).deleteFromMirrors(item)
        verify(timeout = 2_000) { notifications.showError(DELETE_NO_MIRRORS_MESSAGE, any(), any()) }
    }

    // Tron #1783 follow-up 2: a skipped own vault was left out, so the toast read "Deleted from mirrors".
    @Test
    fun `both viewers name a skipped own vault`() {
        val report = BlossomService.MirrorDeleteResult(deleted = listOf("https://cdn.elsewhere.example"), skipped = listOf("https://studio-mac.example.net"))
        val line = "Deleted from mirrors. Skipped: studio-mac.example.net (your own vault)"
        // Each waits for its viewer's onDone, so no view model work outlives the test's Main dispatcher.
        val done = java.util.concurrent.CountDownLatch(2)
        feedViewer(blossom(report)).delete(item.displayUrl, DeleteScope.MIRRORS, deletePosts = false, onDone = { done.countDown() }, onAllGone = {})
        galleryViewer(blossom(report)).deleteFromMirrors(item) { done.countDown() }
        assertTrue(done.await(2, java.util.concurrent.TimeUnit.SECONDS))
        verify(exactly = 2) { notifications.showToast(line, any()) }
    }

    // #5: after a full Delete everywhere the gallery viewer never re-checked, so badges kept the old count.
    @Test
    fun `badges are re-checked after a full delete everywhere`() {
        val blossom = blossom(BlossomService.MirrorDeleteResult(deleted = listOf("https://cdn.elsewhere.example")))
        var allGone: Boolean? = null
        galleryViewer(blossom).deleteEverywhere(item) { allGone = it }
        coVerify(timeout = 2_000) { blossom.checkMirrorStatus(sha, true) }
        assertEquals(true, allGone)
    }

    // #7: the confirmation reads as on iOS (DestructiveConfirmation.swift MediaDeleteConfirmation).
    @Test
    fun `the confirmation text is the iOS text`() {
        assertEquals("Removes this file from all your media servers. Your vault keeps its copy.", deleteBlobConfirmBody(DeleteScope.MIRRORS))
        assertEquals(
            "Permanently removes this file from your vault and all your media servers. This cannot be undone.",
            deleteBlobConfirmBody(DeleteScope.EVERYWHERE),
        )
    }

    @Test
    fun `the share section says where new photos go`() {
        assertEquals(
            "New photos are saved on this device first. If you have a mobile vault, a copy goes to it over the mesh, " +
                "and the mobile vault puts it on your public media server for you. If this device has its own media " +
                "server, it uploads there itself.",
            PHOTOS_ROUTE_LINE,
        )
    }
}
