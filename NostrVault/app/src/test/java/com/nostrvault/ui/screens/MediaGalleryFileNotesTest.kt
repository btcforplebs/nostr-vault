package com.nostrvault.ui.screens

import com.nostrvault.data.local.BlobNoteIndexStore
import com.nostrvault.data.local.ConfigStore
import com.nostrvault.fips.FileNoteTile
import com.nostrvault.fips.FileNotesLive
import com.nostrvault.relay.HavenConfig
import com.nostrvault.service.BlossomService
import com.nostrvault.service.MediaCacheService
import com.nostrvault.service.NostrService
import com.nostrvault.service.StatsService
import com.nostrvault.ui.notification.NotificationManager
import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * The Media tab hears the owner's other devices live (`/files`, plan §1 "Live"): a 1063 lands a tile with no pull, a
 * kind 5 takes it away, and this phone's own copy is the folder watch's, never a note's to drop.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MediaGalleryFileNotesTest {
    private val sha = "ab".repeat(32)
    private val owner = "11".repeat(32)
    private val phone = "22".repeat(32)

    @Before
    fun main() = Dispatchers.setMain(UnconfinedTestDispatcher())

    @After
    fun reset() = Dispatchers.resetMain()

    private fun json(s: String) = Json.parseToJsonElement(s).jsonObject

    private fun note(id: String, x: String = sha, p: String = owner) = json(
        """{"id":"$id","pubkey":"$phone","created_at":1700000000,"kind":1063,"tags":[["x","$x"],["m","image/jpeg"],["size","38091"],["p","$p"],["url","https://cdn.example.com/$x.jpg"]],"content":"","sig":"s"}""",
    )

    private fun deletion(id: String, of: String, x: String = sha) = json(
        """{"id":"$id","pubkey":"$phone","created_at":1700000100,"kind":5,"tags":[["e","$of"],["k","1063"],["x","$x"],["p","$owner"]],"content":"","sig":"s"}""",
    )

    private fun viewModel(
        live: MutableSharedFlow<JsonObject>,
        emojiHidden: MutableStateFlow<Set<String>> = MutableStateFlow(emptySet()),
    ): MediaGalleryViewModel {
        val config = mockk<ConfigStore>(relaxed = true) { every { config } returns MutableStateFlow(HavenConfig()) }
        val nostr = mockk<NostrService>(relaxed = true) { every { ownerHexPubkey } returns owner }
        val stats = mockk<StatsService>(relaxed = true) { coEvery { fetchBlobList(any()) } returns emptyList() }
        val index = mockk<BlobNoteIndexStore>(relaxed = true) {
            every { postDates } returns MutableStateFlow(emptyMap())
            every { authors } returns MutableStateFlow(emptyMap())
        }
        val notes = mockk<FileNotesLive> { every { events(any()) } returns live }
        val emoji = mockk<com.nostrvault.service.emoji.EmojiVaultStore>(relaxed = true) { every { hiddenFromMedia } returns emojiHidden }
        return MediaGalleryViewModel(
            config, nostr, stats, mockk<MediaCacheService>(relaxed = true), mockk<BlossomService>(relaxed = true),
            mockk<NotificationManager>(relaxed = true), index, notes, emoji,
        )
    }

    private fun MediaGalleryViewModel.settle() = runBlocking { withTimeout(5_000) { isLoading.first { !it } } }

    @Test
    fun `a saved custom emoji is not a Media tile, and comes back once it is not hidden`() = runBlocking {
        val live = MutableSharedFlow<JsonObject>()
        val hidden = MutableStateFlow(setOf(sha))
        val vm = viewModel(live, hidden)
        vm.settle()
        live.emit(note("n1"))
        assertTrue(vm.mediaItems.value.isEmpty())
        hidden.value = emptySet()
        assertEquals(sha, withTimeout(5_000) { vm.mediaItems.first { it.isNotEmpty() } }.single().sha256)
    }

    @Test
    fun `a live note lands a tile and its kind 5 takes it away`() = runBlocking {
        val live = MutableSharedFlow<JsonObject>()
        val vm = viewModel(live)
        vm.settle()
        assertTrue(vm.mediaItems.value.isEmpty())

        live.emit(note("n1"))
        val tile = vm.mediaItems.value.single()
        assertEquals(sha, tile.sha256)
        assertEquals("https://cdn.example.com/$sha.jpg", tile.displayUrl)
        assertEquals(false, tile.isLocal)
        assertEquals(1_700_000_000L, tile.uploaded)

        live.emit(deletion("d1", of = "n1"))
        assertTrue(vm.mediaItems.value.isEmpty())
    }

    @Test
    fun `another account's note lands nothing`() = runBlocking {
        val live = MutableSharedFlow<JsonObject>()
        val vm = viewModel(live)
        vm.settle()
        live.emit(note("n1", p = "33".repeat(32)))
        assertTrue(vm.mediaItems.value.isEmpty())
    }

    @Test
    fun `a full load keeps the live tiles`() = runBlocking {
        val live = MutableSharedFlow<JsonObject>()
        val vm = viewModel(live)
        vm.settle()
        live.emit(note("n1"))
        vm.refresh()
        vm.settle()
        assertEquals(listOf(sha), vm.mediaItems.value.map { it.sha256 })
    }

    // The pure merge rules (MediaLiveUpdates.kt)

    private fun tile(urls: List<String> = listOf("https://a.example/$sha")) = FileNoteTile(sha, "image/jpeg", 9, 500, urls)

    private fun local() = BlossomMediaItem(
        sha256 = sha, displayUrl = "/vault/blossom/$sha", localFile = File("/vault/blossom/$sha"),
        mimeType = "image", size = 9, uploaded = null, lastModified = 1_000, isLocal = true,
    )

    @Test
    fun `a vault-only note has no tile yet`() {
        assertNull(MediaLiveRules.noteItem(tile(urls = emptyList())))
    }

    @Test
    fun `a note never replaces a tile already listed`() {
        val here = listOf(local())
        assertEquals(here, MediaLiveRules.noteLanded(here, MediaLiveRules.noteItem(tile())!!))
    }

    @Test
    fun `a note's kind 5 leaves this phone's own copy`() {
        val here = listOf(local())
        assertEquals(here, MediaLiveRules.noteRemoved(here, sha))
        val remote = listOf(MediaLiveRules.noteItem(tile())!!)
        assertTrue(MediaLiveRules.noteRemoved(remote, sha).isEmpty())
    }
}
