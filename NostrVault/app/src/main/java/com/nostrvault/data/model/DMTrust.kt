package com.nostrvault.data.model

/**
 * Who reaches the Messages inbox. A gift-wrapped DM is signed by a throwaway
 * key, so the relay stores every wrap tagged to you whoever sent it; only the
 * opened message names the person, and this check runs on that real sender.
 *
 * A conversation is in the inbox when the other person is in your Web of
 * Trust (you, the people you follow, and the web the relay built from them)
 * or when you have written to them. Following you is not trust: anyone can
 * follow anyone. Everyone else waits under Requests, unread but silent, and
 * answering moves the conversation into the inbox.
 *
 * Fails closed: with no trust graph yet, only conversations you took part in
 * reach the inbox. iOS: DMTrust.swift.
 */
object DMTrust {
    fun isInbox(counterparty: String, youWrote: Boolean, trusted: Set<String>, own: Set<String>): Boolean {
        if (youWrote) return true
        val key = counterparty.lowercase()
        if (own.any { it.lowercase() == key }) return true
        return key in trusted || counterparty in trusted
    }

    data class Split<C>(val inbox: List<C>, val requests: List<C>)

    /** Splits conversations into the inbox and Requests, keeping their order. */
    fun <C> split(
        conversations: List<C>,
        trusted: Set<String>,
        own: Set<String>,
        counterparty: (C) -> String,
        youWrote: (C) -> Boolean,
    ): Split<C> {
        val inbox = mutableListOf<C>()
        val requests = mutableListOf<C>()
        for (c in conversations) {
            if (isInbox(counterparty(c), youWrote(c), trusted, own)) inbox.add(c) else requests.add(c)
        }
        return Split(inbox, requests)
    }
}
