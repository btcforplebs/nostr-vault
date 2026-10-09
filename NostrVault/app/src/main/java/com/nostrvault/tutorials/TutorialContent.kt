package com.nostrvault.tutorials

/** One card: what it says and which `Modifier.tutorialAnchor` it points at
 *  (iOS `TutorialStep`). When that anchor isn't on screen the card shows
 *  without a pointer. The wording matches iOS `TutorialContent.swift`. */
data class TutorialStep(val anchor: String?, val title: String, val body: String)

/** Shown in Settings → Tutorials. */
val TutorialID.title: String
    get() = when (this) {
        TutorialID.FILL_YOUR_VAULT -> "Fill Your Feed"
        TutorialID.FEEDS -> "Your Feeds"
        TutorialID.WOT -> "Your Web of Trust"
        TutorialID.VAULT -> "Your Vault"
        TutorialID.WALLET_CONNECT -> "Wallet Connect"
        TutorialID.POCKET_RELAY -> "Vault in Your Pocket"
        TutorialID.IMPORT_TOUR -> "How Your Vault Works"
    }

val TutorialID.summary: String
    get() = when (this) {
        TutorialID.FILL_YOUR_VAULT -> "Follow your first people and build your web of trust."
        TutorialID.FEEDS -> "What each feed shows and how to pick yours."
        TutorialID.WOT -> "The people you follow, how anyone reaches you, and keeping it fresh."
        TutorialID.VAULT -> "Everything you've posted, kept on this device."
        TutorialID.WALLET_CONNECT -> "Link a wallet so you can send zaps."
        TutorialID.POCKET_RELAY -> "A personal relay and media server, and how it differs from public relays."
        TutorialID.IMPORT_TOUR -> "Your own copy, your relay, and public relays."
    }

/** The cards, in order. Empty for Fill your vault, which draws its own guide. */
val TutorialID.steps: List<TutorialStep>
    get() = when (this) {
        TutorialID.FEEDS -> TutorialContent.feeds
        TutorialID.WOT -> TutorialContent.wot
        TutorialID.VAULT -> TutorialContent.vault
        TutorialID.WALLET_CONNECT -> TutorialContent.walletConnect
        TutorialID.POCKET_RELAY -> TutorialContent.pocketRelay
        TutorialID.IMPORT_TOUR -> TutorialContent.importTour
        TutorialID.FILL_YOUR_VAULT -> emptyList()
    }

/** Whether it can run in this build. Settings lists only these, so Replay
 *  never starts a tutorial with nothing to draw. */
val TutorialID.isAvailable: Boolean
    get() = if (this == TutorialID.FILL_YOUR_VAULT) TutorialContent.FILL_YOUR_VAULT_HAS_GUIDE else steps.isNotEmpty()

/** The tutorial a "Next" button on this one's last card starts: the first
 *  available page tutorial after it, in iOS order. Null when there is none,
 *  so the last card just says Done. Fill your feed's last card hands over to
 *  Feeds. Passing over Wallet Connect once a wallet is linked is the
 *  runner's job (iOS `TutorialCenter.next(after:)`), not this list's. */
val TutorialID.next: TutorialID?
    get() {
        val index = TutorialContent.ORDER.indexOf(this)
        if (index < 0) return null
        return TutorialContent.ORDER.drop(index + 1).firstOrNull { it.isAvailable }
    }

object TutorialContent {
    /** The guide is `FillYourFeedOverlay`. */
    const val FILL_YOUR_VAULT_HAS_GUIDE = true

    /** The order the "Next: …" chain walks. The import tour isn't in it.
     *  Your Vault hands over to Vault in Your Pocket: its last card points
     *  at the Vault button that opens the dashboard. */
    val ORDER = listOf(
        TutorialID.FILL_YOUR_VAULT,
        TutorialID.FEEDS,
        TutorialID.WOT,
        TutorialID.VAULT,
        TutorialID.POCKET_RELAY,
        TutorialID.WALLET_CONNECT,
    )

    const val FEED_PICKER = "feeds.picker"

    /** The row of buttons at the top right of the feed. */
    const val FEED_TOOLBAR = "feeds.toolbar"

    /** Kept to what each corner does and how trust works: the picker lists
     *  the feeds itself. */
    val feeds = listOf(
        TutorialStep(
            FEED_PICKER, "Pick your feed",
            "Tap here to switch feeds. Nostr has no algorithm, so you decide what you see.",
        ),
        TutorialStep(
            FEED_TOOLBAR, "Tune this feed",
            "These buttons change what this feed shows, like reposts and replies. Each feed has its own set.",
        ),
        TutorialStep(
            FEED_TOOLBAR, "Global and your web of trust",
            "On Global, a shield appears here. It keeps Global to your web of trust (people you follow and the people they follow), so spam stays out. Tap it to see everyone. Tap WOT to see your web.",
        ),
    )

    /** The WOT tab's globe, its search field and its refresh button. Tal's
     *  three stops (#451) in Tod's copy (nostr-vault Tutorial thread
     *  2026-10-09): "people you follow", never "graph" or "hops". The list
     *  button is left out on purpose. */
    const val WOT_GLOBE = "wot.globe"
    const val WOT_SEARCH = "wot.search"
    const val WOT_REFRESH = "wot.refresh"

    val wot = listOf(
        TutorialStep(
            WOT_GLOBE, "Your web of trust",
            "These faces are the people you follow. The ones you interact with most sit in front. Tap a face to follow their path, and use the chips across the top to step back.",
        ),
        TutorialStep(
            WOT_SEARCH, "Find someone",
            "Type any name to see how that person reaches you, either through someone you follow or \"Not in your web\". It's a quick way to know whether to trust an account.",
        ),
        TutorialStep(
            WOT_REFRESH, "Keep it fresh",
            "Tap here to re-read who you follow, rebuild your web and load pictures. A full rebuild can take a few minutes, so let the bar finish.",
        ),
    )

    /** The Vault tab's dropdown pill and its floating Vault button. Each
     *  half carries them. Two cards since the Vault tab (Tod's copy,
     *  Nostr-Vault Marketing 2026-10-09); the button hands off to Vault in
     *  Your Pocket on the dashboard. */
    const val VAULT_MODES = "vault.modes"
    const val VAULT_RELAY = "vault.relay"

    val vault = listOf(
        TutorialStep(
            VAULT_MODES, "Your vault",
            "Everything you post, like, zap and save, kept right here on your phone. Tap to pick what you see: notes, articles, media and more.",
        ),
        TutorialStep(
            VAULT_RELAY, "Your relay",
            "Your vault is a real relay, running on this phone. Tap Vault to watch it work.",
        ),
    )

    /** The wallet's "No Wallet Connected" card and its Connect button. Only
     *  shown with no wallet linked: its cards point at the empty card. */
    const val WALLET_EMPTY = "wallet.empty"
    const val WALLET_CONNECT_BUTTON = "wallet.connect"

    val walletConnect = listOf(
        TutorialStep(
            WALLET_EMPTY, "Zaps are bitcoin tips",
            "A zap sends bitcoin straight to the person who posted. Nobody in the middle takes a cut.",
        ),
        TutorialStep(
            WALLET_EMPTY, "Your money stays in your wallet",
            "Nostr Vault never holds your bitcoin. It connects to a wallet app you already use.",
        ),
        TutorialStep(
            WALLET_CONNECT_BUTTON, "Link your wallet",
            "In your wallet app, look for Nostr Wallet Connect (NWC) and copy the connection link. Then tap here and paste it.",
        ),
    )

    /** The Vault Dashboard's status card, the address in it, and the
     *  activity card under it. Tod's "vault in your pocket" copy: a personal
     *  relay and Blossom server, not a "pocket relay". */
    const val RELAY_STATUS = "relay.status"
    const val RELAY_ADDRESS = "relay.address"
    const val RELAY_ACTIVITY = "relay.activity"

    val pocketRelay = listOf(
        TutorialStep(
            RELAY_STATUS, "Your vault, in your pocket",
            "Your vault is a personal Nostr relay and a Blossom media server, running on this phone. It keeps a full copy of your notes and media.",
        ),
        TutorialStep(
            RELAY_ACTIVITY, "It sends your posts out",
            "When you post, your vault keeps a copy and sends it on to the public relays you picked. Watch it happen here.",
        ),
        TutorialStep(
            RELAY_ADDRESS, "Personal vs public",
            "Public relays are shared servers that anyone can post to. Your vault is personal: this address only works on this phone, so nobody else can connect to it unless you turn on Share my relay under Mesh in Settings and add the friends who can reach you. If you want a public address that's always on, run Nostr Vault on a Mac with your own domain. That part is optional.",
        ),
    )

    /** Shown while "I already use Nostr" imports. No anchors: in setup
     *  they're the screen's own cards, and a replay from Settings shows them
     *  low and centred. The last "Ready" card with real counts belongs to the
     *  setup screen only. */
    val importTour = listOf(
        TutorialStep(
            null, "Your notes, your copy",
            "Your notes sit on relays you don't own, and any of those relays can delete them. Importing saves your own copy on this device.",
        ),
        TutorialStep(
            null, "A vault in your pocket",
            "Nostr Vault runs a personal relay and a Blossom media server on your phone. It keeps everything and sends your posts out to the relays you pick. Nobody on the network can connect to it unless you turn on mesh sharing.",
        ),
        TutorialStep(
            null, "Personal vs public relays",
            "Public relays are shared servers that everyone posts to. Your vault is personal, and you decide whether anyone else can reach it. You post to it, and it sends your posts out to the public relays.",
        ),
        TutorialStep(
            null, "Want a public address?",
            "Run Nostr Vault on a Mac with your own domain, and it becomes a public relay that's always on. Your phone syncs with it. This is optional: your vault works fine on its own.",
        ),
        TutorialStep(
            null, "Your feed, your rules",
            "No algorithm picks for you. Your feeds are filtered through the people you follow, so spam stays out.",
        ),
    )
}
