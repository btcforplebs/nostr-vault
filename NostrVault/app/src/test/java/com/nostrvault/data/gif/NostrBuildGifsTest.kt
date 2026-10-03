package com.nostrvault.data.gif

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NostrBuildGifsTest {
    @Test fun decodesItemsAndFallsBackToStill() {
        val body = """{"items":[
          {"id":"a","url":"https://i.nostr.build/a.gif","width":480,"height":270,"title":"Cat",
           "previews":{"w240":{"width":240,"height":135,"animated":"https://i.nostr.build/a_240.webp","still":"https://i.nostr.build/a_240.png"}}},
          {"id":"b","url":"https://i.nostr.build/b.gif","width":100,"height":400,"title":"",
           "previews":{"w240":{"width":0,"height":0,"animated":null,"still":"https://i.nostr.build/b_240.png"}}},
          {"id":"c","url":"http://insecure/c.gif","width":1,"height":1,"title":"","previews":{"w240":{"width":1,"height":1,"still":"x"}}},
          {"id":"d","url":"https://i.nostr.build/d.gif","width":1,"height":1,"title":""}
        ]}"""
        val gifs = NostrBuildGifs.decode(body)
        assertEquals(listOf("a", "b"), gifs.map { it.id })
        assertEquals("https://i.nostr.build/a_240.webp", gifs[0].previewUrl)
        assertEquals(240f / 135f, gifs[0].aspectRatio, 0.001f)
        assertEquals("https://i.nostr.build/b_240.png", gifs[1].previewUrl)
        assertEquals(0.5f, gifs[1].aspectRatio, 0.001f) // 100/400 clamped up to 0.5
    }

    @Test fun garbageIsEmpty() {
        assertTrue(NostrBuildGifs.decode("<html>").isEmpty())
        assertTrue(NostrBuildGifs.decode("""{"items":"no"}""").isEmpty())
    }

    @Test fun searchUrlPages() {
        assertEquals("https://gifs.nostr.build/api/v1/search?q=cat%20jump&limit=24&offset=48",
            NostrBuildGifs.searchUrl("cat jump", 2))
    }
}
