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
        TutorialID.IMPORT_TOUR -> "How Your Vault Works"
    }

/** The cards, in order. Empty for Fill your vault, which draws its own
 *  guide, and for tutorials whose page isn't wired up yet. */
val TutorialID.steps: List<TutorialStep>
    get() = when (this) {
        TutorialID.FEEDS -> TutorialContent.feeds
        TutorialID.IMPORT_TOUR -> TutorialContent.importTour
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

    /** Shown while "I already use Nostr" imports. No anchors: in setup
     *  they're the screen's own cards, and a replay from Settings shows them
     *  low and centred. The last "Ready" card with real counts belongs to the
     *  setup screen only. Same wording as iOS `TutorialContent.importTour`. */
    val importTour = listOf(
        TutorialStep(
            null, "Your notes, your copy",
            "Your notes live on relays you don't own, and any of them can delete them. Importing makes a copy that lives on this device.",
        ),
        TutorialStep(
            null, "A relay in your pocket",
            "Nostr Vault runs a real relay on your phone. It keeps everything and sends your posts out to the relays you pick. Nothing on the network can reach in.",
        ),
        TutorialStep(
            null, "Public relays vs yours",
            "Public relays are shared servers everyone posts to. Yours is your own copy. You post from your vault, and it sends the post out.",
        ),
        TutorialStep(
            null, "Want an address?",
            "Run Nostr Vault on a Mac with your own domain and it becomes a public relay that's up 24/7. Your phone syncs from it. Without one, your pocket relay is all you need.",
        ),
        TutorialStep(
            null, "Your feed, your rules",
            "No algorithm. Your feeds are filtered by the people you follow, so spam stays out.",
        ),
    )

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
