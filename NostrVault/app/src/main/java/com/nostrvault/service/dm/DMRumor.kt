package com.nostrvault.service

/**
 * What a NIP-17 rumor is besides its content: a kind 14 message, or a kind 15 file message
 * ([DMFile]) whose file tags follow the p tag, as the web's rumorFor (dms.js). [notBefore] dates it
 * no earlier than that second, so a photo sent after its words sorts below them.
 */
data class DMRumor(
    val kind: Int = 14,
    val fileTags: List<List<String>> = emptyList(),
    val notBefore: Long = 0,
) {
    fun build(senderPubkey: String, recipientPubkey: String, content: String): String =
        EventPublisher.buildUnsignedEvent(
            pubkey = senderPubkey,
            kind = kind,
            content = content,
            tags = listOf(listOf("p", recipientPubkey)) + fileTags,
            notBefore = notBefore,
        )

    companion object {
        fun file(message: DMFile.Message, notBefore: Long = 0) = DMRumor(15, message.tags, notBefore)
    }
}

/** A locked photo to send ([DMFile.fileMessage]), dated no earlier than [notBefore]. */
data class DMFileSend(val message: DMFile.Message, val notBefore: Long = 0)
