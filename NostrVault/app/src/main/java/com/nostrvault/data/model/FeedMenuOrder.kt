package com.nostrvault.data.model

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Which feeds the feed picker lists, and in what order. The reader edits
 * both; stored as enum names so a feed added in a later version still
 * appears (at its default place) and one that was removed is dropped.
 * iOS: FeedMenuOrder (Models/FeedLayoutMode.swift).
 */
object FeedMenuOrder {
    /**
     * The feeds to list, in the reader's order. New feeds the stored order
     * doesn't know about go in after the feed that precedes them by default.
     */
    fun ordered(stored: List<String>, defaults: List<String>): List<String> {
        val seen = HashSet<String>()
        val out = stored.filter { it in defaults && seen.add(it) }.toMutableList()
        for ((index, value) in defaults.withIndex()) {
            if (value in seen) continue
            val before = defaults.subList(0, index).lastOrNull { it in out }
            out.add(before?.let { out.indexOf(it) + 1 } ?: 0, value)
            seen.add(value)
        }
        return out
    }

    /** [ordered], less the hidden feeds. [pinned] (the home feed) can't be hidden. */
    fun visible(stored: List<String>, hidden: List<String>, defaults: List<String>, pinned: String): List<String> {
        val hiddenSet = hidden.toSet() - pinned
        return ordered(stored, defaults).filter { it !in hiddenSet }
    }

    fun decode(string: String): List<String> = string.split(",").filter { it.isNotEmpty() }

    fun encode(values: List<String>): String = values.joinToString(",")
}

/**
 * The reader's feed picker settings: order and hidden feeds. Following is
 * the home feed and can't be hidden. Read by the feed's own picker, the hold
 * Feed tab picker and its accessibility actions, so all three list the same
 * feeds in the same order.
 */
object FeedMenuSettings {
    private const val PREFS = "feed_menu"
    private const val ORDER_KEY = "order"
    private const val HIDDEN_KEY = "hidden"

    val PINNED = FeedMode.FOLLOWING
    private val defaults: List<String> get() = FeedMode.entries.map { it.name }

    data class Stored(val order: String = "", val hidden: String = "")

    private var prefs: SharedPreferences? = null
    private val _stored = MutableStateFlow(Stored())
    val stored: StateFlow<Stored> = _stored.asStateFlow()

    fun init(context: Context) {
        if (prefs != null) return
        val p = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs = p
        _stored.value = Stored(p.getString(ORDER_KEY, "") ?: "", p.getString(HIDDEN_KEY, "") ?: "")
    }

    /** Every feed, in the reader's order, hidden ones included: the editor's list. */
    fun menuOrder(stored: Stored = _stored.value): List<FeedMode> =
        FeedMenuOrder.ordered(FeedMenuOrder.decode(stored.order), defaults).mapNotNull(::modeNamed)

    /** The feeds the pickers list, in the reader's order. */
    fun menuModes(stored: Stored = _stored.value): List<FeedMode> =
        FeedMenuOrder.visible(
            FeedMenuOrder.decode(stored.order),
            FeedMenuOrder.decode(stored.hidden),
            defaults,
            PINNED.name,
        ).mapNotNull(::modeNamed)

    fun hidden(stored: Stored = _stored.value): Set<FeedMode> =
        FeedMenuOrder.decode(stored.hidden).mapNotNull(::modeNamed).toSet() - PINNED

    /** The default order is stored as empty, so later versions' defaults still apply. */
    fun save(order: List<FeedMode>, hidden: Set<FeedMode>) {
        val next = Stored(
            order = if (order == FeedMode.entries) "" else FeedMenuOrder.encode(order.map { it.name }),
            hidden = FeedMenuOrder.encode(order.filter { it in hidden && it != PINNED }.map { it.name }),
        )
        _stored.value = next
        prefs?.edit()?.putString(ORDER_KEY, next.order)?.putString(HIDDEN_KEY, next.hidden)?.apply()
    }

    private fun modeNamed(name: String): FeedMode? = FeedMode.entries.find { it.name == name }
}
