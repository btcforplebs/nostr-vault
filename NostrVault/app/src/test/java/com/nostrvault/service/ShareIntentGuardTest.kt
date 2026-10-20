package com.nostrvault.service

import android.net.Uri
import io.mockk.mockk
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The share-to-Blossom intake: another app may only hand us its own content.
 * A file:// URI, or one naming a provider of ours, is read with our
 * permissions, so any app could have us upload our private files (the
 * config, with the keys) to Blossom (Android review K1, 2026-10-20). A
 * malformed EXTRA_STREAM is dropped, not cast (X2).
 */
class ShareIntentGuardTest {
    private val own = "com.nostrvault.app"

    @Test
    fun aFileUriIntoOurOwnDataIsRefused() {
        assertFalse(isReadableShare("file", null, null, own))
        assertFalse(isReadableShare("file", "", null, own))
        assertFalse(isReadableShare("FILE", "localhost", null, own))
    }

    @Test
    fun onlyContentUrisAreRead() {
        assertFalse(isReadableShare(null, "media", "com.android.providers.media", own))
        assertFalse(isReadableShare("http", "example.com", null, own))
        assertFalse(isReadableShare("android.resource", own, own, own))
        assertTrue(isReadableShare("content", "media", "com.android.providers.media", own))
        assertTrue(isReadableShare("CONTENT", "com.google.android.apps.photos.contentprovider", "com.google.android.apps.photos", own))
    }

    @Test
    fun ourOwnProvidersAreRefusedByNameAndByOwner() {
        assertFalse(isReadableShare("content", own, null, own))
        assertFalse(isReadableShare("content", "$own.androidx-startup", own, own))
        assertFalse(isReadableShare("content", "$own.fileprovider", null, own))
        // A cross-profile authority carries the user id first.
        assertFalse(isReadableShare("content", "0@$own.fileprovider", null, own))
        // An authority named like someone else's that the system says is ours.
        assertFalse(isReadableShare("content", "innocent.looking", own, own))
        // A lookalike package is not us.
        assertTrue(isReadableShare("content", "com.nostrvault.apple.files", "com.nostrvault.apple", own))
    }

    @Test
    fun anotherAppsProviderWeCannotSeeIsStillRead() {
        // Package visibility can hide another app's provider from the lookup.
        assertTrue(isReadableShare("content", "com.example.gallery.files", null, own))
    }

    @Test
    fun aMissingAuthorityIsRefused() {
        assertFalse(isReadableShare("content", null, null, own))
        assertFalse(isReadableShare("content", "  ", null, own))
        assertFalse(isReadableShare("content", "0@", null, own))
    }

    @Test
    fun aMalformedStreamIsDroppedNotCast() {
        val a = mockk<Uri>()
        val b = mockk<Uri>()
        assertEquals(listOf(a), sharedStreamUris(a))
        assertEquals(listOf(a, b), sharedStreamUris(arrayListOf(a, b)))
        // A list of path strings, or anything that isn't a Uri, used to be cast and crash.
        assertEquals(listOf(b), sharedStreamUris(arrayListOf<Any?>("/data/data/$own/files/nostrvault_config.json", b, null, 7)))
        assertEquals(emptyList<Uri>(), sharedStreamUris("/sdcard/a.png"))
        assertEquals(emptyList<Uri>(), sharedStreamUris(null))
    }
}
