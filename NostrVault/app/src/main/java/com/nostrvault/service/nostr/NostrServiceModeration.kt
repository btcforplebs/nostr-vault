package com.nostrvault.service

    internal fun NostrService.reportEventImpl(eventId: String, pubkey: String, reason: String, description: String? = null) {
        val tags = mutableListOf(
            listOf("e", eventId),
            listOf("p", pubkey),
            listOf("reason", reason),
        )
        signAndPost(kind = 1984, content = description ?: "", tags = tags)
    }

    internal fun NostrService.reportUserImpl(pubkey: String, reason: String, description: String? = null) {
        val tags = mutableListOf(
            listOf("p", pubkey),
            listOf("reason", reason),
        )
        signAndPost(kind = 1984, content = description ?: "", tags = tags)
    }
