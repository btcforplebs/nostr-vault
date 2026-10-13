package com.nostrvault.service

/**
 * The system tray entries [LocalNotificationService] posts: one per event,
 * keyed by the event id itself. Android keys a notification by (tag, id), so
 * the id string is the tag and the number is fixed: two events whose ids hash
 * alike can never replace or cancel each other, which a 32-bit
 * `hashCode()` as the number allowed.
 *
 * Also remembers the events whose in-app pill was read, so a quiet filing of
 * that pill can't land after it was read (iOS `markRead`/`fileMissed`). Both
 * run under one lock, so whichever comes second wins correctly: read after
 * filed removes the entry; filed after read posts nothing.
 */
class NotificationTray<N>(private val system: Platform<N>) {

    /** The tray itself: NotificationManagerCompat in the app, a map in tests. */
    interface Platform<N> {
        fun notify(tag: String, id: Int, notification: N)
        fun cancel(tag: String, id: Int)
    }

    private val lock = Any()
    private val read = LinkedHashSet<String>()

    /**
     * Posts [notification] for event [key]. A [filedPill] (the quiet entry for
     * a pill that was not read) is dropped if the pill has since been read.
     * Returns whether it was posted.
     */
    fun post(key: String, notification: N, filedPill: Boolean = false): Boolean = synchronized(lock) {
        if (filedPill && key in read) return false
        system.notify(key, ID, notification)
        true
    }

    /**
     * The in-app pill for event [key] was read or tapped: its tray entry, if
     * any, goes. The launcher badge goes with it, since Android counts a
     * badge from the app's notifications still in the tray and the app
     * publishes no number of its own.
     */
    fun markRead(key: String) = synchronized(lock) {
        read.remove(key)
        read.add(key)
        if (read.size > MAX_READ) read.iterator().let { it.next(); it.remove() }
        system.cancel(key, ID)
    }

    companion object {
        /** The fixed number every tagged entry uses; the tag tells them apart. */
        const val ID = 1
        private const val MAX_READ = 500
    }
}
