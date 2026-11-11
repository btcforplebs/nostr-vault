package com.nostrvault.ui.screens

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The composer's "Pick from your media" opens full height, as on iPhone (a
 * plain `.sheet`, ComposeView.swift). The grid was capped at 400 dp, so the
 * sheet, which only grows to its content, stopped at about half the phone
 * (Logen 2026-11-11).
 */
class BlossomPickerFullHeightTest {
    private val src = File("src/main/java/com/nostrvault/ui/screens/compose/BlossomMediaPickerSheet.kt").readText()

    @Test
    fun `the grid is not capped`() {
        assertFalse(Regex("""heightIn\s*\(\s*max\s*=""").containsMatchIn(src))
    }

    @Test
    fun `the sheet fills the height and the grid takes what is left`() {
        val column = src.substringAfter("ModalBottomSheet(").substringAfter("Column(").substringBefore(") {")
        assertTrue(column, column.contains(".fillMaxHeight()"))
        val grid = src.substringAfter("LazyColumn(").substringBefore(") {")
        assertTrue(grid, grid.contains("Modifier.weight(1f)"))
    }

    @Test
    fun `it opens fully, and swipe down still closes it`() {
        assertTrue(src.contains("skipPartiallyExpanded = true"))
        assertTrue(src.contains("onDismissRequest = onDismiss"))
    }
}
