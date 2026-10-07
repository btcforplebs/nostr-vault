import SwiftUI

/// UserDefaults as the store for tutorial progress.
final class UserDefaultsTutorialStore: TutorialStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? { defaults.string(forKey: key) }

    func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// The app's one tutorial runner. Pages ask it to start their tutorial;
/// `TutorialStage` draws the cards for whichever one is active.
///
/// Fill your vault draws its own guide: it shows while
/// `isActive(.fillYourVault)` and calls `finish` or `skip` itself.
///
/// `account` is always the active account's hex pubkey: Fill your vault is
/// about whose follows you're looking at, and the page tutorials' gate reads
/// that same account's Fill your vault status.
@MainActor
final class TutorialCenter: ObservableObject {
    static let shared = TutorialCenter()

    @Published private var progress: TutorialProgress
    /// Which card of the active tutorial is showing.
    @Published private(set) var stepIndex = 0
    /// Where each `.tutorialAnchor` is on screen, in global coordinates.
    @Published private(set) var anchors: [String: CGRect] = [:]
    /// Bumped whenever a status is saved. Pages key their start on it, so
    /// Fill your vault being marked done quietly (an account that already
    /// follows people) lets that page's tutorial start in the same launch.
    @Published private(set) var revision = 0

    init(store: TutorialStore = UserDefaultsTutorialStore()) {
        progress = TutorialProgress(store: store)
    }

    var active: TutorialID? { progress.active }

    func isActive(_ id: TutorialID) -> Bool { progress.active == id }

    func status(_ id: TutorialID, account: String) -> TutorialStatus {
        progress.status(id, account: account)
    }

    func startIfEligible(_ id: TutorialID, account: String) {
        guard id.isAvailable, progress.startIfEligible(id, account: account) else { return }
        stepIndex = 0
    }

    func replay(_ id: TutorialID) {
        guard id.isAvailable else { return }
        progress.replay(id)
        stepIndex = 0
    }

    func finish(_ id: TutorialID, account: String) {
        progress.finish(id, account: account)
        revision += 1
    }

    func skip(_ id: TutorialID, account: String) {
        progress.skip(id, account: account)
        revision += 1
    }

    func resetAll(account: String) {
        progress.resetAll(account: account)
        revision += 1
    }

    // MARK: Cards

    var currentStep: TutorialStep? {
        guard let id = progress.active else { return nil }
        let steps = id.steps
        return steps.indices.contains(stepIndex) ? steps[stepIndex] : nil
    }

    var isLastStep: Bool {
        guard let id = progress.active else { return true }
        return stepIndex >= id.steps.count - 1
    }

    func next(account: String) {
        guard let id = progress.active else { return }
        if isLastStep {
            finish(id, account: account)
        } else {
            stepIndex += 1
        }
    }

    func back() {
        if stepIndex > 0 { stepIndex -= 1 }
    }

    // MARK: Anchors

    func setAnchor(_ name: String, frame: CGRect?) {
        guard anchors[name] != frame else { return }
        anchors[name] = frame
    }
}

extension View {
    /// Marks this view as something a tutorial card can point at.
    func tutorialAnchor(_ name: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            TutorialCenter.shared.setAnchor(name, frame: frame)
        }
        .onDisappear {
            TutorialCenter.shared.setAnchor(name, frame: nil)
        }
    }
}
