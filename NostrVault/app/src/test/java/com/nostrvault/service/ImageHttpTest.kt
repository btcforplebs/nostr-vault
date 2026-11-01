package com.nostrvault.service

import org.junit.Assert.assertSame
import org.junit.Test

/** Pictures and media share one connection pool. */
class ImageHttpTest {
    @Test
    fun `the image client and its derived clients share one pool`() {
        assertSame(ImageHttp.root.connectionPool, ImageHttp.images.connectionPool)
        assertSame(ImageHttp.images, com.nostrvault.di.AppModule.imageHttpClient())
    }
}
