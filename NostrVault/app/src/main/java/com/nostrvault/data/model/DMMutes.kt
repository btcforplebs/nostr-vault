package com.nostrvault.data.model

/**
 * DMs and the mute list's words (Logen 2026-11-27): a muted word in a message
 * someone sent you hides the whole conversation row. It stays in the inbox
 * data, and "N hidden: muted word" shows it again. Your own messages never
 * hide a conversation. iOS: DMInboxView; web: dms.js.
 */
object DMMutes {
    /** Whether [rules] hide a conversation of [messages]: one you received holds a muted word. */
    fun <M> hides(messages: List<M>, rules: MuteRules, isFromMe: (M) -> Boolean, content: (M) -> String): Boolean =
        !rules.isEmpty && messages.any { !isFromMe(it) && rules.hidesText(content(it)) }

    /** [conversations] split into (shown, hidden by a muted word). */
    fun <C> split(conversations: List<C>, hides: (C) -> Boolean): Pair<List<C>, List<C>> =
        conversations.partition { !hides(it) }
}
