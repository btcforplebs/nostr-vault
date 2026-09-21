package com.nostrvault.data.model

import java.util.Date

/** One note placed in a thread, carrying how deep it sits under the root. */
data class FeedThreadEntry(
    val note: FeedNote,
    /**
     * 0 for the root, 1 for a direct reply, and so on. Capped by
     * [FeedThreadGrouping.MAX_DEPTH] so a long argument cannot indent the
     * content off a phone screen.
     */
    val depth: Int,
) {
    val id: String get() = note.id
}

/**
 * A root note plus every reply to it present in the feed, flattened into
 * reading order.
 */
data class FeedThread(
    /** The thread root's event ID, present whether or not the root itself loaded. */
    val rootId: String,
    /**
     * The root note, or null when the feed only carries replies to it and the
     * root has not been fetched yet.
     */
    val root: FeedNote?,
    /** Root first (when present), then replies depth-first, oldest sibling first. */
    val entries: List<FeedThreadEntry>,
    /**
     * Newest `createdAt` anywhere in the thread — what the feed sorts on, so a
     * thread rises when someone replies rather than staying pinned to the
     * root's age.
     */
    val latestActivity: Date,
) {
    val id: String get() = rootId

    /** Everything below the root, in the same order as [entries]. */
    val replies: List<FeedThreadEntry>
        get() = if (root == null) entries else entries.filter { it.note.id != root.id }
}

/** Mirrors iOS `FeedThreadGrouping.swift`: pure logic, no service/view dependency. */
object FeedThreadGrouping {
    /**
     * Indentation stops here; deeper replies keep their order but share the
     * last rail, which is what every readable mobile thread does.
     */
    const val MAX_DEPTH = 4

    private const val MAX_HOPS = 64

    /**
     * Arrange a flat, newest-first feed into threads.
     *
     * @param notes the feed as rendered today, in feed order.
     * @param resolveNote looks up a note that is referenced but not in
     *   [notes] (an ancestor the feed never showed). Returning null is fine —
     *   the thread is then rooted at the highest ancestor that did load.
     * @return threads ordered by `latestActivity`, newest first.
     */
    fun build(
        notes: List<FeedNote>,
        resolveNote: (String) -> FeedNote? = { null },
    ): List<FeedThread> {
        if (notes.isEmpty()) return emptyList()

        // Everything we can see: the feed plus any ancestor we can resolve.
        val pool = LinkedHashMap<String, FeedNote>()
        for (note in notes) pool[note.id] = note

        for (note in notes) {
            var currentId = note.parentEventId
            var hops = 0
            while (currentId != null && pool[currentId] == null && hops < MAX_HOPS) {
                val resolved = resolveNote(currentId) ?: break
                pool[currentId] = resolved
                currentId = resolved.parentEventId
                hops++
            }
        }

        // Resolve each feed note to the topmost ancestor we actually have.
        val rootIdCache = HashMap<String, String>()
        fun rootIdFor(note: FeedNote): String {
            rootIdCache[note.id]?.let { return it }

            val chain = mutableListOf<String>()
            var current = note
            var hops = 0
            while (true) {
                val parentId = current.parentEventId ?: break
                if (hops >= MAX_HOPS) break
                chain.add(current.id)
                val parent = pool[parentId]
                if (parent == null) {
                    // The parent never loaded. NIP-10 may still name the real
                    // root, which keeps sibling branches of one conversation
                    // together instead of scattering them.
                    val resolved = taggedRootId(current) ?: parentId
                    for (id in chain) rootIdCache[id] = resolved
                    rootIdCache[note.id] = resolved
                    return resolved
                }
                current = parent
                hops++
            }

            val resolved = current.id
            for (id in chain) rootIdCache[id] = resolved
            rootIdCache[note.id] = resolved
            return resolved
        }

        // Group, preserving the order roots first appear in the feed so a
        // stable tie-break exists for threads sharing a timestamp.
        val order = mutableListOf<String>()
        val grouped = HashMap<String, MutableList<FeedNote>>()
        val seenInGroup = HashMap<String, MutableSet<String>>()

        fun add(note: FeedNote, root: String) {
            if (seenInGroup[root]?.contains(note.id) == true) return
            val bucket = grouped.getOrPut(root) {
                seenInGroup[root] = mutableSetOf()
                order.add(root)
                mutableListOf()
            }
            bucket.add(note)
            seenInGroup[root]?.add(note.id)
        }

        for (note in notes) {
            val root = rootIdFor(note)
            add(note, root)

            // Pull in resolved ancestors between this note and the root so the
            // thread reads as a chain rather than jumping over missing links.
            var currentId = note.parentEventId
            var hops = 0
            while (currentId != null && hops < MAX_HOPS) {
                val ancestor = pool[currentId] ?: break
                add(ancestor, root)
                currentId = ancestor.parentEventId
                hops++
            }
        }

        val threads = order.mapNotNull { root ->
            val members = grouped[root] ?: return@mapNotNull null
            val rootNote = members.firstOrNull { it.id == root }
            val entries = flatten(members, root)
            val latest = members.maxOfOrNull { it.createdAt } ?: Date(0)
            FeedThread(rootId = root, root = rootNote, entries = entries, latestActivity = latest)
        }

        return threads.sortedWith(
            compareByDescending<FeedThread> { it.latestActivity }
                .thenBy { order.indexOf(it.rootId) }
        )
    }

    /**
     * Depth-first walk from the root, oldest sibling first, so a thread reads
     * top to bottom the way it was written.
     */
    private fun flatten(members: List<FeedNote>, rootId: String): List<FeedThreadEntry> {
        val byId = members.associateBy { it.id }

        val children = HashMap<String, MutableList<FeedNote>>()
        val tops = mutableListOf<FeedNote>()
        for (note in members) {
            if (note.id == rootId) continue
            // A note whose parent is missing from this group still belongs to
            // the thread; hang it off the root rather than dropping it.
            val parentId = note.parentEventId
            if (parentId != null && byId[parentId] != null && parentId != note.id) {
                children.getOrPut(parentId) { mutableListOf() }.add(note)
            } else {
                tops.add(note)
            }
        }
        for (key in children.keys) {
            children[key]?.sortBy { it.createdAt }
        }
        tops.sortBy { it.createdAt }

        val entries = mutableListOf<FeedThreadEntry>()
        val visited = mutableSetOf<String>()

        fun visit(note: FeedNote, depth: Int) {
            if (!visited.add(note.id)) return
            entries.add(FeedThreadEntry(note = note, depth = minOf(depth, MAX_DEPTH)))
            for (child in children[note.id] ?: emptyList()) {
                visit(child, depth + 1)
            }
        }

        val root = byId[rootId]
        if (root != null) {
            visit(root, 0)
            for (top in tops) visit(top, 1)
        } else {
            // Root never loaded: its direct replies become the top level.
            for (top in tops) visit(top, 1)
        }

        return entries
    }

    /** The `root`-marked e-tag from NIP-10, when the author wrote one. */
    private fun taggedRootId(note: FeedNote): String? =
        note.tags.firstOrNull { it.size >= 4 && it[0] == "e" && it[3] == "root" }?.get(1)
}
