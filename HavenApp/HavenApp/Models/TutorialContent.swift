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
        }
    }

    var summary: String {
        switch self {
        case .fillYourVault: return "Follow your first people and build your web of trust."
        case .feeds: return "What each feed shows and how to pick yours."
        case .vault: return "Everything you've posted, kept on this device."
        case .walletConnect: return "Link a wallet so you can send zaps."
        case .pocketRelay: return "Who can reach the relay in your pocket."
        }
    }

    var symbolName: String {
        switch self {
        case .fillYourVault: return "person.2.badge.plus"
        case .feeds: return "rectangle.stack"
        case .vault: return "lock.shield"
        case .walletConnect: return "bolt.fill"
        case .pocketRelay: return "antenna.radiowaves.left.and.right"
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

    /// The guide is `FillYourFeedOverlay`.
    static let fillYourVaultHasGuide = true
}

enum TutorialContent {
    static let feedPicker = "feeds.picker"

    /// Plan: PLANS/NOSTR_VAULT_REPLAYABLE_TUTORIALS.md, "1. Feeds". Discover
    /// is `extendedNetworkPubkeys`: people your follows follow, ranked by how
    /// many of your follows follow them.
    static let feeds: [TutorialStep] = [
        TutorialStep(
            anchor: feedPicker,
            title: "Pick your feed here",
            body: "Nostr has no algorithm. Each feed is a different way to look at the network, and you choose which one."
        ),
        TutorialStep(
            anchor: feedPicker,
            title: "Following is home",
            body: "Only the people you follow, newest first."
        ),
        TutorialStep(
            anchor: feedPicker,
            title: "Discover",
            body: "People your follows follow, the most shared first. The easiest place to find your next follow."
        ),
        TutorialStep(
            anchor: feedPicker,
            title: "Global and Hashtags",
            body: "Wider than your follows. Once you follow people, they're filtered by your web of trust, so strangers' spam stays out."
        ),
        TutorialStep(
            anchor: feedPicker,
            title: "One kind of post",
            body: "Media, diVines, Articles, Recipes, Marketplace, Live and Music each show just that kind of post."
        ),
        TutorialStep(
            anchor: feedPicker,
            title: "Make it yours",
            body: "Edit Feeds, at the bottom of this menu, hides the feeds you don't use and changes their order."
        ),
    ]
}
