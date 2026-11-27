package com.nostrvault.ui.screens.profile

/**
 * The profile tab row keeps [PINNED] kinds as icon tabs and puts every other
 * kind on show behind a fourth "more" tab. The more tab takes the icon of the
 * kind picked from it, so the row still says which kind is open.
 */
internal object ProfileTabSlots {
    const val PINNED = 3

    data class Slots(
        /** The icon tabs, in order. */
        val tabs: List<ProfileSection>,
        /** The kinds in the more list, in order; empty when there is no more tab. */
        val more: List<ProfileSection>,
    )

    fun of(visible: List<ProfileSection>): Slots =
        // Four kinds fit as four tabs; a more tab would only hide the fourth.
        if (visible.size <= PINNED + 1) Slots(visible, emptyList())
        else Slots(visible.take(PINNED), visible.drop(PINNED))

    /** The kind the more tab stands for: the open kind when it is in the list, else none. */
    fun moreSelection(slots: Slots, selected: ProfileSection): ProfileSection? =
        selected.takeIf { it in slots.more }
}
