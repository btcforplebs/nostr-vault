import Foundation

/// One card of a tutorial: what it says, and which part of the screen it
/// points at. `anchor` matches a `.tutorialAnchor(_:)` somewhere in the UI;
/// when that view isn't on screen the card shows without an arrow rather
/// than pointing at nothing.
struct TutorialStep: Equatable {
    let anchor: String?
    let title: String
    let body: String
}

extension TutorialID {
    /// Shown in Settings → Tutorials.
    var title: String {
        switch self {
        case .fillYourVault: return "Fill Your Feed"
        case .feeds: return "Your Feeds"
        case .vault: return "Your Vault"
        case .walletConnect: return "Wallet Connect"
        case .pocketRelay: return "Pocket Relay vs Public Relay"
        case .importTour: return "How Your Vault Works"
        }
    }

    var summary: String {
        switch self {
        case .fillYourVault: return "Follow your first people and build your web of trust."
        case .feeds: return "What each feed shows and how to pick yours."
        case .vault: return "Everything you've posted, kept on this device."
        case .walletConnect: return "Link a wallet so you can send zaps."
        case .pocketRelay: return "Who can reach the relay in your pocket."
        case .importTour: return "Your own copy, your relay, and public relays."
        }
    }

    var symbolName: String {
        switch self {
        case .fillYourVault: return "person.2.badge.plus"
        case .feeds: return "rectangle.stack"
        case .vault: return "lock.shield"
        case .walletConnect: return "bolt.fill"
        case .pocketRelay: return "antenna.radiowaves.left.and.right"
        case .importTour: return "tray.and.arrow.down"
        }
    }

    /// The cards, in order. Empty for Fill your vault, which draws its own
    /// guide, and for tutorials whose page isn't wired up yet.
    var steps: [TutorialStep] {
        switch self {
        case .feeds:
            // Its anchor is the iPhone/iPad feed picker; the Mac has none yet.
            #if os(iOS)
            return TutorialContent.feeds
            #else
            return []
            #endif
        case .importTour: return TutorialContent.importTour
        case .fillYourVault, .vault, .walletConnect, .pocketRelay: return []
        }
    }

    /// Whether it can run in this build: the page tutorials once they have
    /// cards, Fill your vault once its guide (feat/fill-your-vault) is in.
    /// Settings lists only these, so Replay never starts a tutorial with
    /// nothing to draw.
    var isAvailable: Bool {
        self == .fillYourVault ? Self.fillYourVaultHasGuide : !steps.isEmpty
    }

    /// The tutorial a "Next" button on this one's last card starts: the
    /// first available page tutorial after it. Nil when none is built yet,
    /// so the last card just says Done.
    var next: TutorialID? {
        let order: [TutorialID] = [.feeds, .vault, .walletConnect, .pocketRelay]
        guard let index = order.firstIndex(of: self) else { return nil }
        return order[(index + 1)...].first { $0.isAvailable }
    }

    /// The guide is `FillYourFeedOverlay`.
    static let fillYourVaultHasGuide = true
}

enum TutorialContent {
    static let feedPicker = "feeds.picker"

    /// The pill of buttons at the top right of the feed.
    static let feedToolbar = "feeds.toolbar"

    /// Plan: PLANS/NOSTR_VAULT_REPLAYABLE_TUTORIALS.md, "1. Feeds". Kept to
    /// what each corner does and how trust works (Logen, nostr-vault
    /// Tutorial thread 2026-10-08): the picker lists the feeds itself.
    static let feeds: [TutorialStep] = [
        TutorialStep(
            anchor: feedPicker,
            title: "Pick your feed",
            body: "Tap here to switch feeds. Nostr has no algorithm, so you choose what you see."
        ),
        TutorialStep(
            anchor: feedToolbar,
            title: "Tune this feed",
            body: "These buttons change what this feed shows, like reposts and replies. They're different on each feed."
        ),
        TutorialStep(
            anchor: feedToolbar,
            title: "Following, Global and trust",
            body: "On wider feeds you'll see a globe for Global. It shows people your follows follow, your web of trust, so spam stays out. The shield opens it to everyone."
        ),
    ]

    /// Shown while "I use Nostr" imports (Tory's draft, nostr-vault Tutorial
    /// thread 2026-10-07). No anchors: in setup they're the screen's own
    /// cards, and a replay from Settings shows them low and centred. The
    /// last "Ready" card with real counts belongs to the setup screen only.
    /// Wording matches website/index.html "Two ways to run it".
    static let importTour: [TutorialStep] = [
        TutorialStep(
            anchor: nil,
            title: "Your notes, your copy",
            body: "Your notes live on relays you don't own, and any of them can delete them. Importing makes a copy that lives on this device."
        ),
        TutorialStep(
            anchor: nil,
            title: "A relay in your pocket",
            body: "Nostr Vault runs a real relay on your phone. It keeps everything and sends your posts out to the relays you pick. Nothing on the network can reach in."
        ),
        TutorialStep(
            anchor: nil,
            title: "Public relays vs yours",
            body: "Public relays are shared servers everyone posts to. Yours is your own copy. You post from your vault, and it sends the post out."
        ),
        TutorialStep(
            anchor: nil,
            title: "Want an address?",
            body: "Run Nostr Vault on a Mac with your own domain and it becomes a public relay that's up 24/7. Your phone syncs from it. Without one, your pocket relay is all you need."
        ),
        TutorialStep(
            anchor: nil,
            title: "Your feed, your rules",
            body: "No algorithm. Your feeds are filtered by the people you follow, so spam stays out."
        ),
    ]
}
