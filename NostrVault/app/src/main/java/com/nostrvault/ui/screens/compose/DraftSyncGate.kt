package com.nostrvault.ui.screens

/**
 * Whether the composer going to the background should send its draft to the
 * relay (one signer request). Picking a photo or video opens another app,
 * which stops the composer too; that isn't leaving, so it doesn't count.
 */
internal class DraftSyncGate {
    private var pickerOpen = false

    /** Just before a photo or video picker opens. */
    fun pickerOpening() { pickerOpen = true }

    /** The composer is on screen again (back from the picker, or from the background). */
    fun started() { pickerOpen = false }

    /** On ON_STOP: true unless the stop is the picker opening. */
    fun syncOnStop(): Boolean = !pickerOpen
}
