package com.nostrvault.ui.components

/**
 * The web address a shared note points at.
 *
 * One definition, because there were about to be three: the broadcast sheet
 * built this string, the feed's Copy link built it again, and the next surface
 * that wants to share a note would have built a fourth. If the host ever
 * changes, it changes here.
 */
internal const val THREAD_LINK_HOST = "https://mynostrspace.com"

/** Shareable web link for a note, given its `nevent1…` (or `note1…`) reference. */
internal fun threadLink(reference: String): String = "$THREAD_LINK_HOST/thread/$reference"
