package com.nostrvault.data.model

/**
 * When a DM may alert (Logen 2026-11-01). A gift wrap (kind 1059) names no
 * author until it is unlocked, and every DM you send also wraps a copy to
 * yourself, which reaches your other devices. So a gift wrap never alerts
 * before it is unlocked, however long that takes: it waits in
 * [PendingDMAlerts] until the inbox opens it with its usual decrypt, and is
 * then decided here. iOS: DMAlertGate in NotificationPolicy.swift.
 */
object DMAlertGate {
    /**
     * Whether an unlocked DM alerts: not from any account on this device
     * (another device's self-copy, or one of your accounts writing another),
     * not from a blocked person, not a Request from outside your Web of
     * Trust, and not in the conversation already on screen.
     */
    fun alerts(
        sender: String,
        isFromMe: Boolean,
        ownAccounts: Set<String>,
        blocked: Set<String>,
        inInbox: Boolean,
        onScreen: Boolean,
    ): Boolean {
        if (isFromMe || sender.isEmpty() || ownAccounts.any { it.equals(sender, ignoreCase = true) }) return false
        if (BlockedPeople.isBlocked(sender, blocked)) return false
        return inInbox && !onScreen
    }
}

/**
 * Gift-wrap alerts waiting for their DM to be unlocked, by wrap id. The oldest
 * go first past [limit]: a wrap that never opens (another account that is
 * never switched to, unreadable data) must not pile up. Thread-safe: markers
 * arrive on one thread and the inbox opens DMs on another.
 */
class PendingDMAlerts<T>(private val limit: Int = 256) {
    private val entries = LinkedHashMap<String, T>()

    val size: Int get() = synchronized(entries) { entries.size }

    fun add(id: String, value: T) = synchronized(entries) {
        if (entries.containsKey(id)) return@synchronized
        entries[id] = value
        while (entries.size > limit) entries.remove(entries.keys.first())
    }

    /** The entry for [id], removed, or null when none waits. */
    fun take(id: String): T? = synchronized(entries) { entries.remove(id) }
}
