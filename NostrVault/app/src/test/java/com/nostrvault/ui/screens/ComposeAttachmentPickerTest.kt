package com.nostrvault.ui.screens

import androidx.activity.result.contract.ActivityResultContracts.PickMultipleVisualMedia
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The compose screen rebuilds its picker contract on every recomposition, so
 * the value it hands `PickMultipleVisualMedia` has to be one the contract will
 * accept for *any* attachment count — not just the empty case.
 */
class ComposeAttachmentPickerTest {

    /**
     * Positive control: without it, a broken [pickerMaxItems] and a contract
     * that silently accepts anything would look the same from here.
     */
    @Test
    fun `the contract rejects a single item`() {
        try {
            PickMultipleVisualMedia(maxItems = 1)
            fail("expected PickMultipleVisualMedia(1) to be rejected")
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message.orEmpty().contains("higher than 1"))
        }
    }

    @Test
    fun `every attachment count produces a maxItems the contract accepts`() {
        for (attached in 0..MAX_ATTACHMENTS) {
            // Throws IllegalArgumentException if the value is 1 or less — which
            // is exactly what used to happen at three attachments.
            PickMultipleVisualMedia(maxItems = pickerMaxItems(attached))
        }
    }

    @Test
    fun `asks for the free slots while more than one is left`() {
        assertEquals(4, pickerMaxItems(0))
        assertEquals(3, pickerMaxItems(1))
        assertEquals(2, pickerMaxItems(2))
    }

    @Test
    fun `floors at two once one slot or none is left`() {
        assertEquals(2, pickerMaxItems(3))
        assertEquals(2, pickerMaxItems(MAX_ATTACHMENTS))
    }
}
