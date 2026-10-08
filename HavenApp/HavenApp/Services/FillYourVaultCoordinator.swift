import Foundation
import Combine
import CoreGraphics

/// Applies `FillYourVaultRule` to the active account's follow list: starts the
/// guide for a new account, marks it done without showing it for an account
/// that already follows 5, and finishes it when the feed fills. Also keeps
/// the web of trust (10 follows) once earned, and moves the "Fill your feed" guide between its
/// screens (`phase`). `FillYourFeedOverlay` draws what this publishes.
@MainActor
final class FillYourVaultCoordinator: ObservableObject {
    static let shared = FillYourVaultCoordinator()

    /// The meter for the active account, rebuilt on every follow change.
    @Published private(set) var meter = VaultMeter(follows: [], owner: "", masterEarned: false)
    /// Set when this account reaches the web of trust (10 follows) for the first time; the
    /// meter plays the gold bolt once and clears it.
    @Published var celebrateVaultMaster = false
    /// Which of the guide's screens is up.
    @Published private(set) var phase: FillYourFeedPhase = .off
    /// Whether the meter is on for this account (see `FeedMeterStore`).
    @Published private(set) var meterOn = false
    /// The meter folded down to its pill.
    @Published var meterCollapsed = false
    /// The open meter's measured height. Post rises by it and the feed
    /// scrolls clear of it (Tory: Post keeps priority).
    @Published var meterHeight: CGFloat = 0
    /// The person whose small profile card is open.
    @Published var profileCardPubkey: String?
    /// Topics picked in this run, so "Only my web of trust" drops just those.
    private(set) var pickedTopics: [String] = []

    private let masterStore = VaultMasterStore()
    private let meterStore = FeedMeterStore(store: UserDefaultsTutorialStore())
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    /// Count the last time the rule ran, per account; nil before the list is known.
    private var lastCount: (account: String, count: Int)?
    private var wasActive = false

    private init() {}

    private var account: String { ConfigService.shared.activeAccountHexPubkey }

    /// True while the meter is drawn.
    var meterShowing: Bool { FillYourFeedGuide.showsMeter(phase: phase, meterOn: meterOn) }

    /// How far the open meter pushes Post up and the feed's end in. The
    /// collapsed pill shares Post's row on the leading edge, so it takes none.
    var meterLift: CGFloat {
        meterShowing && !meterCollapsed && meterHeight > 0 ? meterHeight + FloatingButtonRow.gap : 0
    }

    func start() {
        guard !started else { return }
        started = true
        let feed = FeedService.shared
        // @Published fires before the new value is stored, so hop to the next
        // main-queue turn and read the settled state from the services.
        Publishers.Merge4(
            feed.$followedPubkeys.map { _ in () },
            feed.$isLoadingContacts.map { _ in () },
            feed.$contactListConfirmed.map { _ in () },
            ConfigService.shared.$activeAccountHexPubkey.map { _ in () }
        )
        .merge(with: feed.$hasAttemptedContactLoad.map { _ in () })
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.update() }
        .store(in: &cancellables)

        // The engine starts the guide (or Settings replays it): open it.
        TutorialCenter.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.followEngine() }
            .store(in: &cancellables)

        ConfigService.shared.$activeAccountHexPubkey
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.loadMeterState() }
            .store(in: &cancellables)
    }

    // MARK: - Guide steps

    /// Intro: "Let's fill it".
    func beginFilling() {
        meterStore.set(true, account: account)
        meterOn = true
        meterCollapsed = false
        phase = .topics
    }

    /// Topics: "Show posts". Follows the picked hashtags (one published
    /// list) and opens the topic feed behind the hint.
    func showPosts(topics: [String]) {
        pickedTopics = topics
        let interests = InterestListService.shared
        let new = topics.filter { !interests.isFollowing($0) }
        if !new.isEmpty {
            Task { await interests.setFollowing(new, true) }
        }
        FeedService.shared.switchMode(.hashtags)
        phase = .hint
    }

    /// Hint: "Got it".
    func dismissHint() { phase = .browsing }

    /// "Your feed is ready": go to Following. `keepTopics` false unfollows
    /// the hashtags picked in this run (and only those).
    func goToFollowing(keepTopics: Bool) {
        if !keepTopics, !pickedTopics.isEmpty {
            let topics = pickedTopics
            Task { await InterestListService.shared.setFollowing(topics, false) }
        }
        FeedService.shared.switchMode(.following)
        meterCollapsed = true
        phase = .browsing
    }

    /// The bolt has crossed the meter: show the web-of-trust card.
    func showMasterCard() {
        celebrateVaultMaster = false
        meterCollapsed = false
        phase = .master
    }

    func dismissMasterCard() { phase = .browsing }

    /// Skip, "Not now" or "Hide the meter": the guide closes (done past 5,
    /// skipped below) and the meter goes away.
    func closeGuide() {
        if TutorialCenter.shared.isActive(.fillYourVault) { close() }
        meterStore.set(false, account: account)
        meterOn = false
        profileCardPubkey = nil
        phase = .off
    }

    /// Closing the guide by hand: done past 5, skipped below.
    func close() {
        switch FillYourVaultRule.onClose(count: meter.count) {
        case .done: TutorialCenter.shared.finish(.fillYourVault, account: account)
        default: TutorialCenter.shared.skip(.fillYourVault, account: account)
        }
    }

    // MARK: - State

    private func loadMeterState() {
        meterOn = meterStore.isOn(account: account)
        meterCollapsed = meter.count >= VaultMeter.goal
        profileCardPubkey = nil
        if !TutorialCenter.shared.isActive(.fillYourVault) { phase = .off }
    }

    private func followEngine() {
        // objectWillChange fires before the change lands.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let active = TutorialCenter.shared.isActive(.fillYourVault)
            defer { self.wasActive = active }
            guard active, !self.wasActive else { return }
            self.pickedTopics = []
            let entry = FillYourFeedGuide.entryPhase(meterOn: self.meterOn)
            self.phase = entry
            // Back mid-guide after a relaunch: their topic feed, where they
            // were finding people, not a Following with only a few in it.
            if entry == .browsing, self.meter.count < VaultMeter.goal,
               !InterestListService.shared.hashtags.isEmpty {
                FeedService.shared.switchMode(.hashtags)
            }
        }
    }

    private func update() {
        let feed = FeedService.shared
        let account = self.account
        meter = VaultMeter(follows: feed.followedPubkeys, owner: account,
                           masterEarned: masterStore.isEarned(owner: account))

        let known = feed.followListIsKnown && !account.isEmpty
        let previous = lastCount?.account == account ? lastCount?.count : nil
        if known { lastCount = (account, meter.count) }

        if known, masterStore.record(meter, owner: account) {
            meter = VaultMeter(follows: feed.followedPubkeys, owner: account, masterEarned: true)
            // Only the guide's people get the bolt; someone who never saw
            // the meter just has it recorded.
            if meterOn { celebrateVaultMaster = true }
        }

        let center = TutorialCenter.shared
        switch FillYourVaultRule.onFollowsChanged(
            listKnown: known, previousCount: previous, count: meter.count,
            status: center.status(.fillYourVault, account: account),
            isActive: center.isActive(.fillYourVault)
        ) {
        case .none: break
        case .start: center.startIfEligible(.fillYourVault, account: account)
        case .finishSilently: center.finish(.fillYourVault, account: account)
        case .finish:
            center.finish(.fillYourVault, account: account)
            profileCardPubkey = nil
            phase = .ready
        }
    }
}
