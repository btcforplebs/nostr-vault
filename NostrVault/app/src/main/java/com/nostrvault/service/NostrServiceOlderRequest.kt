package com.nostrvault.service

/**
 * One older page asked of a profile stream: its exact [subId], and how many
 * relays took the REQ. Every one of them answers with an EOSE for [subId],
 * so a page knows when all of them have answered.
 */
data class OlderRequest(val subId: String, val relays: Int)
