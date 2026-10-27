package com.nostrvault.ui.screens

import android.content.Context
import com.nostrvault.fips.MeshAuthor
import com.nostrvault.ui.screens.profile.profileTileImageModel
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Vault → Media and profile Media tiles ask the mesh for the note's author, as the feed does (#1011). */
class VaultMediaMeshAuthorTest {
    private val context = mockk<Context>(relaxed = true)
    private val owner = "c".repeat(64)
    private val friend = "a".repeat(64)
    private val npub = "npub1xlrwmhu" + "q".repeat(51)

    private fun item(url: String) = BlossomMediaItem(
        sha256 = "f".repeat(64), displayUrl = url, localFile = null, mimeType = "image/jpeg",
        size = null, uploaded = null, lastModified = null, isLocal = false,
    )

    @Test
    fun vaultTileOfSomeoneElsesNoteAsksThem() {
        val req = vaultGridImageRequest(context, item("http://$npub.fips/${"f".repeat(64)}"), friend, owner)
        assertEquals(MeshAuthor(friend), req.tags.tag(MeshAuthor::class.java))
    }

    @Test
    fun vaultTileOfYourOwnBlobAsksYourVault() {
        val req = vaultGridImageRequest(context, item("http://$npub.fips/${"f".repeat(64)}"), null, owner)
        assertEquals(MeshAuthor(owner), req.tags.tag(MeshAuthor::class.java))
    }

    @Test
    fun noOwnerLeavesTheVaultTileOffTheMesh() {
        assertNull(vaultTileMeshAuthor(null, ""))
        val req = vaultGridImageRequest(context, item("https://blossom.example/x.jpg"), null, "")
        assertNull(req.tags.tag(MeshAuthor::class.java))
    }

    @Test
    fun profileTileAsksItsAuthor() {
        val still = profileTileImageModel(context, "http://$npub.fips/${"f".repeat(64)}.jpg", friend)
        assertEquals(MeshAuthor(friend), still.tags.tag(MeshAuthor::class.java))
        val gif = profileTileImageModel(context, "http://$npub.fips/${"f".repeat(64)}.gif", friend)
        assertEquals(MeshAuthor(friend), gif.tags.tag(MeshAuthor::class.java))
        assertEquals("http://$npub.fips/${"f".repeat(64)}.gif#still", gif.memoryCacheKey?.key)
    }
}
