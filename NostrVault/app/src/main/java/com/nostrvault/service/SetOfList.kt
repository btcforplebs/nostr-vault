package com.nostrvault.service

/**
 * A list's Set, kept until a different list comes in, so a hot path can test
 * membership without copying the list on every call. Matches by identity: a
 * StateFlow publishes a new list on every change.
 */
internal class SetOfList<T> {
    @Volatile private var last: Pair<List<T>, Set<T>> = emptyList<T>() to emptySet()

    fun of(list: List<T>): Set<T> {
        val cached = last
        if (cached.first === list) return cached.second
        return list.toSet().also { last = list to it }
    }
}
