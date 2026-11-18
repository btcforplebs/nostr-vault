package com.nostrvault.data.model

/**
 * The threads the last [FeedThreadGrouping.build] made, kept so the next build
 * only lays out the threads that changed. A thread is a pure function of its
 * root id and its members in grouping order, so when both are the same notes
 * (the same instances) as last time, the old [FeedThread] is handed back as is:
 * the same order, the same entries, and an instance Compose can skip on. Only a
 * thread a note joined, left or replaced is flattened again. While scrolling
 * the feed regrouped on every arrival, and flattening every thread each time
 * was most of the DefaultDispatcher time (perf review 2026-11-18, item 2).
 */
class FeedThreadMemo {
    private val lock = Any()
    private var kept: Map<String, Pair<List<FeedNote>, FeedThread>> = emptyMap()

    /** The thread kept for [rootId] when it had exactly [members], else null. */
    fun reuse(rootId: String, members: List<FeedNote>): FeedThread? = synchronized(lock) {
        val (old, thread) = kept[rootId] ?: return null
        if (old.size != members.size) return null
        for (i in members.indices) if (old[i] !== members[i]) return null
        thread
    }

    /** Keeps this build's threads (and drops the ones no longer in the feed). */
    fun keep(built: List<Pair<List<FeedNote>, FeedThread>>) = synchronized(lock) {
        kept = built.associateBy({ it.second.rootId }, { it })
    }

    fun clear() = synchronized(lock) { kept = emptyMap() }
}
