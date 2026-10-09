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
        case .wot: return "Your Web of Trust"
        case .vault: return "Your Vault"
        case .walletConnect: return "Wallet Connect"
        case .pocketRelay: return "Vault in Your Pocket"
        case .importTour: return "How Your Vault Works"
        }
    }

    var summary: String {
        switch self {
        case .fillYourVault: return "Follow your first people and build your web of trust."
        case .feeds: return "What each feed shows and how to pick yours."
        case .wot: return "The people you follow, how anyone reaches you, and keeping it fresh."
        case .vault: return "Everything you've posted, kept on this device."
        case .walletConnect: return "Link a wallet so you can send zaps."
        case .pocketRelay: return "A personal relay and media server, and how it differs from public relays."
        case .importTour: return "Your own copy, your relay, and public relays."
        }
    }

    var symbolName: String {
        switch self {
        case .fillYourVault: return "person.2.badge.plus"
        case .feeds: return "rectangle.stack"
        case .wot: return "globe"
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
        case .wot:
            // Its anchors are the WOT tab's globe, search field and refresh button.
            #if os(iOS)
            return TutorialContent.wot
            #else
            return []
            #endif
        case .vault:
            // Its anchors are the iPhone/iPad Vault tab's pill and Vault button.
            #if os(iOS)
            return TutorialContent.vault
            #else
            return []
            #endif
        case .walletConnect:
            // Its anchors are on the iPhone/iPad wallet sheet.
            #if os(iOS)
            return TutorialContent.walletConnect
            #else
            return []
            #endif
        case .pocketRelay:
            // Its anchors are on the iPhone/iPad Vault Dashboard sheet.
            #if os(iOS)
            return TutorialContent.pocketRelay
            #else
            return []
            #endif
        case .importTour: return TutorialContent.importTour
        case .fillYourVault: return []
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
    /// so the last card just says Done. Fill your feed's last card hands
    /// over to Feeds, and Your Vault's to Vault in Your Pocket: its last
    /// card points at the Vault button that opens the dashboard.
    var next: TutorialID? {
        let order: [TutorialID] = [.fillYourVault, .feeds, .wot, .vault, .pocketRelay, .walletConnect]
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
            body: "Tap here to switch feeds. Nostr has no algorithm, so you decide what you see."
        ),
        TutorialStep(
            anchor: feedToolbar,
            title: "Tune this feed",
            body: "These buttons change what this feed shows, like reposts and replies. Each feed has its own set."
        ),
        TutorialStep(
            anchor: feedToolbar,
            title: "Global and your web of trust",
            body: "On Global, a shield appears here. It keeps Global to your web of trust (people you follow and the people they follow), so spam stays out. Tap it to see everyone. Tap WOT to see your web."
        ),
    ]

    /// The WOT tab's globe, its search button and its layer menu (where Rebuild lives).
    static let wotGlobe = "wot.globe"
    static let wotSearch = "wot.search"
    static let wotRefresh = "wot.refresh"

    /// Tal's three stops (#451) in Tod's copy (nostr-vault Tutorial thread
    /// 2026-10-09): "people you follow", never "graph" or "hops". The list
    /// button is left out on purpose.
    static let wot: [TutorialStep] = [
        TutorialStep(
            anchor: wotGlobe,
            title: "Your web of trust",
            body: "These faces are the people you follow. The ones you interact with most sit in front. Tap a face to follow their path, and use the chips across the top to step back."
        ),
        TutorialStep(
            anchor: wotSearch,
            title: "Find someone",
            body: "Tap here and type any name to see how that person reaches you, either through someone you follow or \"Not in your web\". It's a quick way to know whether to trust an account."
        ),
        TutorialStep(
            anchor: wotRefresh,
            title: "Keep it fresh",
            body: "Rebuild your web from this menu. It re-reads who you follow and loads pictures. A full rebuild can take a few minutes, so let it finish."
        ),
    ]

    /// The Vault tab's dropdown pill and its floating Vault button. Both
    /// halves carry them; the one showing takes the card.
    static let vaultModes = "vault.modes"
    static let vaultRelay = "vault.relay"

    /// Plan: PLANS/NOSTR_VAULT_REPLAYABLE_TUTORIALS.md, "2. Your vault".
    /// Two cards since the Vault tab (Tod's copy, Nostr-Vault Marketing
    /// 2026-10-09): the pill is a dropdown now, and the button hands off to
    /// Vault in Your Pocket on the dashboard.
    static let vault: [TutorialStep] = [
        TutorialStep(
            anchor: vaultModes,
            title: "Your vault",
            body: "Everything you post, like, zap and save, kept right here on your phone. Tap to pick what you see: notes, articles, media and more."
        ),
        TutorialStep(
            anchor: vaultRelay,
            title: "Your relay",
            body: "Your vault is a real relay, running on this phone. Tap Vault to watch it work."
        ),
    ]

    /// The wallet's "No Wallet Connected" card and its Connect button.
    static let walletEmpty = "wallet.empty"
    static let walletConnectButton = "wallet.connect"

    /// Plan: PLANS/NOSTR_VAULT_REPLAYABLE_TUTORIALS.md, "3. Wallet Connect".
    /// Only shown with no wallet linked: its cards point at the empty card.
    static let walletConnect: [TutorialStep] = [
        TutorialStep(
            anchor: walletEmpty,
            title: "Zaps are bitcoin tips",
            body: "A zap sends bitcoin straight to the person who posted. Nobody in the middle takes a cut."
        ),
        TutorialStep(
            anchor: walletEmpty,
            title: "Your money stays in your wallet",
            body: "Nostr Vault never holds your bitcoin. It connects to a wallet app you already use."
        ),
        TutorialStep(
            anchor: walletConnectButton,
            title: "Link your wallet",
            body: "In your wallet app, look for Nostr Wallet Connect (NWC) and copy the connection link. Then tap here and paste it."
        ),
    ]

    /// The Vault Dashboard's status card, the address in it, and the
    /// activity card under it.
    static let relayStatus = "relay.status"
    static let relayAddress = "relay.address"
    static let relayActivity = "relay.activity"

    /// Plan: PLANS/NOSTR_VAULT_REPLAYABLE_TUTORIALS.md, "4. Pocket relay vs
    /// public relay", kept short like the others. Wording is Tod's "vault
    /// in your pocket" copy (nostr-vault Tutorial thread 2026-10-09): a
    /// personal relay and Blossom server, not a "pocket relay". Who can
    /// reach it differs by platform since FIPS mesh sharing: Kiosk mode here
    /// opens it to anyone on the mesh, Android's Share my relay only to the
    /// friends you add. Android's lines say so (TutorialWordingParityTest).
    static let pocketRelay: [TutorialStep] = [
        TutorialStep(
            anchor: relayStatus,
            title: "Your vault, in your pocket",
            body: "Your vault is a personal Nostr relay and a Blossom media server, running on this phone. It keeps a full copy of your notes and media."
        ),
        TutorialStep(
            anchor: relayActivity,
            title: "It sends your posts out",
            body: "When you post, your vault keeps a copy and sends it on to the public relays you picked. Watch it happen here."
        ),
        TutorialStep(
            anchor: relayAddress,
            title: "Personal vs public",
            body: "Public relays are shared servers that anyone can post to. Your vault is personal: this address only works on this phone, so nobody else can connect to it unless you turn on Kiosk mode in Settings. If you want a public address that's always on, run Nostr Vault on a Mac with your own domain. That part is optional."
        ),
    ]

    /// Shown while "I use Nostr" imports (Tory's draft, nostr-vault Tutorial
    /// thread 2026-10-07). No anchors: in setup they're the screen's own
    /// cards, and a replay from Settings shows them low and centred. The
    /// last "Ready" card with real counts belongs to the setup screen only.
    /// Vault wording as in `pocketRelay` above.
    static let importTour: [TutorialStep] = [
        TutorialStep(
            anchor: nil,
            title: "Your notes, your copy",
            body: "Your notes sit on relays you don't own, and any of those relays can delete them. Importing saves your own copy on this device."
        ),
        TutorialStep(
            anchor: nil,
            title: "A vault in your pocket",
            body: "Nostr Vault runs a personal relay and a Blossom media server on your phone. It keeps everything and sends your posts out to the relays you pick. Nobody on the network can connect to it unless you turn on Kiosk mode."
        ),
        TutorialStep(
            anchor: nil,
            title: "Personal vs public relays",
            body: "Public relays are shared servers that everyone posts to. Your vault is personal, and you decide whether anyone else can reach it. You post to it, and it sends your posts out to the public relays."
        ),
        TutorialStep(
            anchor: nil,
            title: "Want a public address?",
            body: "Run Nostr Vault on a Mac with your own domain, and it becomes a public relay that's always on. Your phone syncs with it. This is optional: your vault works fine on its own."
        ),
        TutorialStep(
            anchor: nil,
            title: "Your feed, your rules",
            body: "No algorithm picks for you. Your feeds are filtered through the people you follow, so spam stays out."
        ),
    ]
}
