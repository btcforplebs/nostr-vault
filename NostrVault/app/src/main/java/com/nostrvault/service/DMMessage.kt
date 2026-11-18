package com.nostrvault.service

import kotlinx.serialization.Serializable

@Serializable
data class DMMessage(
    val id: String,
    val content: String,
    val timestamp: Long,
    val senderPubkey: String,
    val isFromMe: Boolean,
    val isNIP04: Boolean = false,
    /** Your own message still on its way, or refused everywhere; null once a relay took it (DMDelivery). */
    val sendState: DMSendState? = null,
    /** Why a [DMSendState.FAILED] message didn't go out, in words for the bubble. */
    val failure: String? = null,
    /**
     * The words to send again on Try again after a restart, when the signed copy is gone. Only for a plain
     * text message: a locked photo's link carries its key and is never resent as text.
     */
    val resendText: String? = null,
)

/** Where your own message is (Messages check A2; web `net/dms.js` pending/failed). */
@Serializable
enum class DMSendState { SENDING, FAILED }
