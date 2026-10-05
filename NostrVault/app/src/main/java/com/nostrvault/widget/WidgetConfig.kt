package com.nostrvault.widget

/**
 * Per-widget settings, the Android side of iOS's widget configuration intents
 * (QuickActionsIntent, FeedGlanceIntent, MosaicIntent).
 *
 * Stored in each widget's own Glance state, written by
 * [WidgetConfigActivity]. Kept as plain string maps here so the parsing —
 * including what an unset or stale value falls back to — is unit-testable
 * without Glance or DataStore.
 */

/** A Quick Actions tile (iOS QuickAction). */
enum class QuickAction(
    /** On the tile. */
    val label: String,
    /** In the picker, where there is room to say what it does. */
    val pickerName: String,
    /** The `nostrvault://` destination DeepLinkRouter serves. */
    val destination: String,
    val tint: Long,
) {
    COMPOSE("Post", "New note", "compose", 0xFF8259F0),
    DMS("DMs", "Messages", "dms", 0xFF4FA8FA),
    SEARCH("Search", "Search", "search", 0xFF70C78C),
    RELAY("Relay", "Relay", "relay", 0xFFFA8C24),
    MEDIA("Media", "Media", "media", 0xFFEB6B9E),
    WALLET("Wallet", "Wallet", "wallet", 0xFFFAC73D);

    companion object {
        fun fromKey(key: String?): QuickAction? = entries.firstOrNull { it.name == key }
    }
}

data class QuickActionsConfig(val slots: List<QuickAction> = DEFAULT_SLOTS) {
    fun toEntries(): Map<String, String> =
        slots.mapIndexed { i, action -> slotKey(i) to action.name }.toMap()

    companion object {
        const val SLOT_COUNT = 4
        val DEFAULT_SLOTS = listOf(QuickAction.COMPOSE, QuickAction.DMS, QuickAction.SEARCH, QuickAction.RELAY)
        fun slotKey(i: Int) = "qa.slot$i"

        /** Each slot falls back on its own default, so one bad value does not reset the rest. */
        fun from(get: (String) -> String?): QuickActionsConfig =
            QuickActionsConfig(List(SLOT_COUNT) { i -> QuickAction.fromKey(get(slotKey(i))) ?: DEFAULT_SLOTS[i] })
    }
}

enum class FeedSource(val label: String) { FOLLOWING("Following"), MENTIONS("Mentions") }

enum class FeedDensity(val label: String, val bodyLines: Int) {
    COMFORTABLE("Comfortable", 2), COMPACT("Compact", 1)
}

data class FeedConfig(
    val source: FeedSource = FeedSource.FOLLOWING,
    val density: FeedDensity = FeedDensity.COMFORTABLE,
    val showAvatars: Boolean = true,
) {
    fun toEntries(): Map<String, String> = mapOf(
        SOURCE to source.name,
        DENSITY to density.name,
        AVATARS to showAvatars.toString(),
    )

    companion object {
        const val SOURCE = "feed.source"
        const val DENSITY = "feed.density"
        const val AVATARS = "feed.avatars"

        fun from(get: (String) -> String?): FeedConfig = FeedConfig(
            source = FeedSource.entries.firstOrNull { it.name == get(SOURCE) } ?: FeedSource.FOLLOWING,
            density = FeedDensity.entries.firstOrNull { it.name == get(DENSITY) } ?: FeedDensity.COMFORTABLE,
            showAvatars = get(AVATARS)?.toBooleanStrictOrNull() ?: true,
        )
    }
}

enum class MosaicStyle(val label: String) { GRID("Even grid"), FEATURED("One large, rest small") }

data class MosaicConfig(
    val style: MosaicStyle = MosaicStyle.GRID,
    val rounded: Boolean = true,
) {
    fun toEntries(): Map<String, String> = mapOf(STYLE to style.name, ROUNDED to rounded.toString())

    companion object {
        const val STYLE = "mosaic.style"
        const val ROUNDED = "mosaic.rounded"

        fun from(get: (String) -> String?): MosaicConfig = MosaicConfig(
            style = MosaicStyle.entries.firstOrNull { it.name == get(STYLE) } ?: MosaicStyle.GRID,
            rounded = get(ROUNDED)?.toBooleanStrictOrNull() ?: true,
        )
    }
}
