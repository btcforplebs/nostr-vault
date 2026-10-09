package com.nostrvault.ui.screens

import com.nostrvault.ui.navigation.Screen
import org.junit.Assert.assertEquals
import org.junit.Test

class AddressDestinationTest {
    @Test
    fun `an article opens the reader, anything else the thread`() {
        val id = "e".repeat(64)
        assertEquals(Screen.ArticleReader.createRoute(id), addressDestination(30023, id))
        assertEquals(Screen.NoteDetail.createRoute(id), addressDestination(30311, id))
    }
}
