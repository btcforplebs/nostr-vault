import Foundation

/// The "Fill your feed" guide's screens and the rules for moving between
/// them. No UI here, so the flow is tested on its own; the overlay draws
/// whatever `phase` says. The tutorial ID stays `fill-your-vault` (it is the
/// storage key); people see "Fill your feed". Android: FillYourFeedGuide.kt.
enum FillYourFeedPhase: Equatable {
    /// Nothing from the guide on screen (the meter may still show).
    case off
    /// "Fill your feed": you → your follows → their follows.
    case intro
    /// "What are you into?": the topic chips.
    case topics
    /// "Find people you like": the small hint over the topic feed.
    case hint
    /// No card; the person is browsing with the meter.
    case browsing
    /// "Your web of trust is built", shown once at 5 follows. Its button
    /// opens Discover and starts the Feeds tutorial.
    case ready
}

enum FillYourFeedGuide {
    /// Where the guide opens when the tutorial engine starts it. Someone who
    /// already got past the intro (the meter is on) and relaunched mid-way
    /// goes straight back to the feed rather than seeing the intro again.
    static func entryPhase(meterOn: Bool) -> FillYourFeedPhase {
        meterOn ? .browsing : .intro
    }

    /// Whether the meter is drawn. It belongs to the guide's people: it is
    /// on from "Let's fill it" until they hide it, so an account the guide
    /// finished quietly (it already followed 5) never sees one.
    static func showsMeter(phase: FillYourFeedPhase, meterOn: Bool) -> Bool {
        guard meterOn else { return false }
        switch phase {
        case .intro, .topics: return false
        case .off, .hint, .browsing, .ready: return true
        }
    }

    /// While the meter is up, tapping a person opens the small profile card,
    /// so they can look before they follow.
    static func opensProfileCard(meterShowing: Bool) -> Bool { meterShowing }

    /// The topic step's button.
    static func showPostsTitle(selected: Int) -> String {
        selected == 0 ? "Pick at least one" : "Show posts (\(selected))"
    }

    /// The meter's two lines.
    static func meterTitle(_ meter: VaultMeter, compact: Bool) -> String {
        if meter.stage == .master { return masterTitle }
        return compact ? meter.compactProgressText : meter.progressText
    }

    static func meterSubtitle(_ meter: VaultMeter) -> String {
        switch meter.stage {
        case .filling: return "Look before you follow"
        case .master: return "\(VaultMeter.goal) people followed"
        }
    }

    /// The collapsed pill: "3/5", or the title once built.
    static func pillText(_ meter: VaultMeter) -> String {
        meter.stage == .master ? masterTitle : meter.compactProgressText
    }

    /// Fraction of the pill's ring: progress toward 5.
    static func ringFraction(_ meter: VaultMeter) -> Double {
        meter.stage == .master ? 1 : Double(min(meter.count, VaultMeter.goal)) / Double(VaultMeter.goal)
    }

    /// The meter and pill at 5 (Logen: plain trust wording).
    static let masterTitle = "Web of trust"

    /// The one-time card at 5.
    static let readyTitle = "Your web of trust is built"
    /// The card's button: Discover, where the Feeds tutorial starts.
    static let readyButton = "Next: Discover people"
}

/// Per account: whether the meter is on. Set on "Let's fill it", cleared by
/// "Hide the meter", Skip, "Not now" or the last card's button. Kept so a
/// relaunch mid-guide resumes on the feed with the meter.
struct FeedMeterStore {
    let store: TutorialStore

    private func key(_ account: String) -> String { "fillYourFeed.meter.\(account)" }

    func isOn(account: String) -> Bool {
        !account.isEmpty && store.string(forKey: key(account)) == "on"
    }

    func set(_ on: Bool, account: String) {
        guard !account.isEmpty else { return }
        store.set(on ? "on" : "off", forKey: key(account))
    }
}
