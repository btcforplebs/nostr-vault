package com.nostrvault.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

class AvatarThumbnailTest {

    @Test
    fun `public picture goes through the resizer with the original as fallback`() {
        val original = "https://image.nostr.build/a.gif?x=1&y=2"
        val encoded = "https%3A%2F%2Fimage.nostr.build%2Fa.gif%3Fx%3D1%26y%3D2"
        assertEquals(
            "https://wsrv.nl/?url=$encoded&w=256&h=256&fit=inside&we&output=webp&default=$encoded",
            AvatarThumbnail.url(original),
        )
    }

    @Test
    fun `unreserved characters stay as they are`() {
        val out = AvatarThumbnail.url("https://example.com/a-b_c.d~e")
        assertEquals(true, out.contains("url=https%3A%2F%2Fexample.com%2Fa-b_c.d~e&"))
    }

    @Test
    fun `private, local and tor hosts keep the original`() {
        listOf(
            "http://127.0.0.1:3355/a.png",
            "http://localhost:3355/a.png",
            "http://192.168.1.4/a.png",
            "http://10.0.0.2/a.png",
            "http://172.20.0.1/a.png",
            "http://100.100.1.1/a.png",
            "http://169.254.1.1/a.png",
            "http://box.local/a.png",
            "http://abc.onion/a.png",
            "http://[::1]/a.png",
            "https://wsrv.nl/?url=x",
        ).forEach { assertEquals(it, it, AvatarThumbnail.url(it)) }
    }

    @Test
    fun `non-http and broken urls keep the original`() {
        listOf("data:image/png;base64,AAAA", "blossom:abc", "not a url").forEach {
            assertEquals(it, AvatarThumbnail.url(it))
        }
    }

    @Test
    fun `public ip goes through the resizer`() {
        assertEquals(true, AvatarThumbnail.url("http://8.8.8.8/a.png").startsWith("https://wsrv.nl/"))
        assertEquals(true, AvatarThumbnail.url("http://172.32.0.1/a.png").startsWith("https://wsrv.nl/"))
    }
}
