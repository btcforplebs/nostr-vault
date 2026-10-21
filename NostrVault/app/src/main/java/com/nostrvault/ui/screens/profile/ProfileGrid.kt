package com.nostrvault.ui.screens.profile

/**
 * Column counts for the profile's grids, as iOS lays them out: Media from
 * `AdaptiveLayout.columns(ideal: 180, spacing: 6, 3...6)`, and diVines and
 * Shop from `GridItem(.adaptive(minimum:))`, so a tablet gets more tiles
 * rather than wider ones and a phone keeps the counts it has always had.
 */
internal object ProfileGrid {
    const val MEDIA_SPACING_DP = 6f

    /** The phone counts, kept on any device narrower than a tablet. */
    const val PHONE_MEDIA = 3
    const val PHONE_DIVINES = 3
    const val PHONE_SHOP = 2

    /**
     * iOS `AdaptiveLayout.usesWidth`: only the iPad lays its grids out from
     * its width, so a phone (even in landscape) keeps the phone counts. 0
     * means "use the phone counts"; tablets are `smallestScreenWidthDp` 600+.
     */
    fun layoutWidth(screenWidthDp: Float, smallestScreenWidthDp: Int): Float =
        if (smallestScreenWidthDp >= 600) screenWidthDp else 0f

    /** iOS `AdaptiveGridLayout.columnCount`: tiles of about [ideal] across [width], clamped. */
    fun columnCount(width: Float, ideal: Float, spacing: Float, minimum: Int, maximum: Int): Int {
        if (width <= 0f || ideal <= 0f || maximum < minimum) return minimum
        val fitting = ((width + spacing) / (ideal + spacing)).toInt()
        return fitting.coerceIn(minimum, maximum)
    }

    /** SwiftUI `.adaptive(minimum:)`: as many columns of at least [minimum] as fit, at least one. */
    fun adaptiveCount(width: Float, minimum: Float, spacing: Float): Int =
        maxOf(1, ((width + spacing) / (minimum + spacing)).toInt())

    /** The media grid on a tablet: 8 dp padding each side, 3 to 6 columns. [widthDp] is from [layoutWidth]. */
    fun mediaColumns(widthDp: Float): Int =
        if (widthDp <= 0f) PHONE_MEDIA
        else columnCount(widthDp - 16f, ideal = 180f, spacing = MEDIA_SPACING_DP, minimum = PHONE_MEDIA, maximum = 6)

    /** diVines: 16 dp padding each side, columns at least 110 wide, 4 apart. */
    fun divineColumns(widthDp: Float): Int =
        if (widthDp <= 0f) PHONE_DIVINES else adaptiveCount(widthDp - 32f, minimum = 110f, spacing = 4f)

    /** Shop: 16 dp padding each side, cards at least 150 wide, 12 apart. */
    fun shopColumns(widthDp: Float): Int =
        if (widthDp <= 0f) PHONE_SHOP else adaptiveCount(widthDp - 32f, minimum = 150f, spacing = 12f)
}
