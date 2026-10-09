package com.nostrvault.ui.screens.profile

import com.nostrvault.data.model.FeedProfile
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfileEditAutosaveTest {
    private val shown = mapOf("display_name" to "Satoshi", "name" to "sat", "about" to "hi", "website" to "")
    private val existing = FeedProfile(pubkey = "ab", name = "sat", displayName = "Satoshi", about = "hi",
        lud06 = "lnurl1abc", createdAt = 100)

    @Test fun untouchedFormHasNoChanges() {
        assertFalse(ProfileMetadataMerge.hasChanges(shown, shown))
    }

    @Test fun whitespaceOnlyEditIsNotAChange() {
        assertFalse(ProfileMetadataMerge.hasChanges(shown, shown + ("about" to " hi\n")))
    }

    @Test fun realEditIsAChange() {
        assertTrue(ProfileMetadataMerge.hasChanges(shown, shown + ("website" to "a.example")))
    }

    @Test fun previewAppliesEditsAndClearsEmptiedFields() {
        val out = ProfileMetadataMerge.preview(existing, shown, shown + ("about" to "") + ("website" to " a.example "))
        assertNull(out.about)
        assertEquals("a.example", out.website)
        assertEquals("Satoshi", out.bestName)
        // Fields the form does not show are left alone.
        assertEquals("lnurl1abc", out.lud06)
        assertEquals(100L, out.createdAt)
    }

    @Test fun profileIgnoresNonStringValues() {
        val content = JsonObject(mapOf("name" to JsonPrimitive(5), "about" to JsonObject(emptyMap()), "nip05" to JsonPrimitive("me@x")))
        val out = ProfileMetadataMerge.profile(existing, content)
        assertNull(out.name)
        assertNull(out.about)
        assertEquals("me@x", out.nip05)
    }
}
