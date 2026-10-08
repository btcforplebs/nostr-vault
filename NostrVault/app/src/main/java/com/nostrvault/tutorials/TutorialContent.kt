package com.nostrvault.tutorials

/** One card: what it says and which `Modifier.tutorialAnchor` it points at
 *  (iOS `TutorialStep`). The wording matches iOS `TutorialContent.swift`. */
data class TutorialStep(val anchor: String?, val title: String, val body: String)

val TutorialID.title: String
    get() = when (this) {
        TutorialID.FILL_YOUR_VAULT -> "Fill Your Feed"
        TutorialID.FEEDS -> "Your Feeds"
        TutorialID.VAULT -> "Your Vault"
        TutorialID.WALLET_CONNECT -> "Wallet Connect"
        TutorialID.POCKET_RELAY -> "Pocket Relay vs Public Relay"
    }

/** The cards, in order. Empty for Fill your vault, which draws its own
 *  guide, and for tutorials whose page isn't wired up yet. */
val TutorialID.steps: List<TutorialStep>
    get() = when (this) {
        TutorialID.FEEDS -> TutorialContent.feeds
        else -> emptyList()
    }

/** Whether it can run in this build. Settings lists only these, so Replay
 *  never starts a tutorial with nothing to draw. */
val TutorialID.isAvailable: Boolean
    get() = if (this == TutorialID.FILL_YOUR_VAULT) TutorialContent.FILL_YOUR_VAULT_HAS_GUIDE else steps.isNotEmpty()

object TutorialContent {
    /** The guide is `FillYourFeedOverlay`. */
    const val FILL_YOUR_VAULT_HAS_GUIDE = true

    const val FEED_PICKER = "feeds.picker"

    /** Discover is the extended network: people your follows follow, ranked
     *  by how many of your follows follow them. */
    val feeds = listOf(
        TutorialStep(
            FEED_PICKER, "Pick your feed here",
            "Nostr has no algorithm. Each feed is a different way to look at the network, and you choose which one.",
        ),
        TutorialStep(FEED_PICKER, "Following is home", "Only the people you follow, newest first."),
        TutorialStep(
            FEED_PICKER, "Discover",
            "People your follows follow, the most shared first. The easiest place to find your next follow.",
        ),
        TutorialStep(
            FEED_PICKER, "Global and Hashtags",
            "Wider than your follows. Once you follow people, they're filtered by your web of trust, so strangers' spam stays out.",
        ),
        TutorialStep(
            FEED_PICKER, "One kind of post",
            "Media, diVines, Articles, Recipes, Marketplace, Live and Music each show just that kind of post.",
        ),
        TutorialStep(
            FEED_PICKER, "Make it yours",
            "Edit Feeds, at the bottom of this menu, hides the feeds you don't use and changes their order.",
        ),
    )
}
