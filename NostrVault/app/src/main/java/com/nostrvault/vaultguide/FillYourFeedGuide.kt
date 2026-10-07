package com.nostrvault.vaultguide

import com.nostrvault.tutorials.TutorialStore

/**
 * The "Fill your feed" guide's screens and the rules for moving between
 * them. No UI here, so the flow is tested on its own; the overlay draws
 * whatever `phase` says. The tutorial ID stays `fill-your-vault` (it is the
 * storage key); people see "Fill your feed". iOS: FillYourFeedGuide.swift.
 */
enum class FillYourFeedPhase {
    /** Nothing from the guide on screen (the meter may still show). */
    OFF,
    /** "Fill your feed": you → your follows → their follows. */
    INTRO,
    /** "What are you into?": the topic chips. */
    TOPICS,
    /** "Find people you like": the small hint over the topic feed. */
    HINT,
    /** No card; the person is browsing with the meter. */
    BROWSING,
    /** "Your feed is ready", shown once at 5 follows. */
    READY,
    /** The one-time "Your web of trust is built" card at 10. */
    MASTER,
}

object FillYourFeedGuide {
    /** The meter and pill at 10 (Logen: plain trust wording). */
    const val MASTER_TITLE = "Web of trust"

    /** The one-time card at 10. */
    const val MASTER_CARD_TITLE = "Your web of trust is built"
    const val MASTER_CARD_BODY = "Your feed now comes from 10 people you chose, and the people they trust."

    /**
     * Where the guide opens when the tutorial engine starts it. Someone who
     * already got past the intro (the meter is on) and relaunched mid-way
     * goes straight back to the feed.
     */
    fun entryPhase(meterOn: Boolean): FillYourFeedPhase =
        if (meterOn) FillYourFeedPhase.BROWSING else FillYourFeedPhase.INTRO

    /**
     * Whether the meter is drawn. It is on from "Let's fill it" until it is
     * hidden, so an account the guide finished quietly never sees one.
     */
    fun showsMeter(phase: FillYourFeedPhase, meterOn: Boolean): Boolean =
        meterOn && phase != FillYourFeedPhase.INTRO && phase != FillYourFeedPhase.TOPICS

    /** While the meter is up, tapping a person opens the small profile card. */
    fun opensProfileCard(meterShowing: Boolean): Boolean = meterShowing

    fun showPostsTitle(selected: Int): String =
        if (selected == 0) "Pick at least one" else "Show posts ($selected)"

    fun meterTitle(meter: VaultMeter, compact: Boolean): String = when {
        meter.stage == VaultMeter.Stage.MASTER -> MASTER_TITLE
        compact -> meter.compactProgressText
        else -> meter.progressText
    }

    fun meterSubtitle(meter: VaultMeter): String = when (meter.stage) {
        VaultMeter.Stage.FILLING -> "Look before you follow"
        VaultMeter.Stage.FILLED -> "10 builds your web of trust"
        VaultMeter.Stage.MASTER -> "${VaultMeter.MASTER_GOAL} people followed"
    }

    fun pillText(meter: VaultMeter): String =
        if (meter.stage == VaultMeter.Stage.MASTER) MASTER_TITLE else meter.compactProgressText

    fun ringFraction(meter: VaultMeter): Float =
        if (meter.stage == VaultMeter.Stage.MASTER) 1f
        else minOf(meter.count, VaultMeter.MASTER_GOAL).toFloat() / VaultMeter.MASTER_GOAL
}

/**
 * Per account: whether the meter is on. Set on "Let's fill it", cleared by
 * "Hide the meter", Skip or "Not now".
 */
class FeedMeterStore(private val store: TutorialStore) {
    private fun key(account: String) = "fillYourFeed.meter.$account"

    fun isOn(account: String): Boolean = account.isNotEmpty() && store.getString(key(account)) == "on"

    fun set(on: Boolean, account: String) {
        if (account.isEmpty()) return
        store.putString(key(account), if (on) "on" else "off")
    }
}
