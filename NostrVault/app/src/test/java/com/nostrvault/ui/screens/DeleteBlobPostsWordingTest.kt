package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Test

/** Wording matches iOS `confirmMediaDelete` (DestructiveConfirmation.swift). */
class DeleteBlobPostsWordingTest {
    @Test
    fun `button names one post or the count`() {
        assertEquals("Delete file and post", deleteBlobWithPostsLabel(1))
        assertEquals("Delete file and 3 posts", deleteBlobWithPostsLabel(3))
    }

    @Test
    fun `message says the post will show a broken image and goes whole`() {
        assertEquals(
            " One of your posts uses it and will show a broken image unless you delete that post too." +
                " Deleting the post removes all of it: its text and any other photos in it.",
            deleteBlobPostsNote(1),
        )
        assertEquals(
            " 2 of your posts use it and will show a broken image unless you delete them too." +
                " Deleting a post removes all of it: its text and any other photos in it.",
            deleteBlobPostsNote(2),
        )
    }
}
