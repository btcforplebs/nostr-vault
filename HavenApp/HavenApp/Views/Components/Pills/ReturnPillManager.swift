import SwiftUI

/// The one pill for what came in while the app was away. The app coming back
/// from the background opens a `ReturnWindow`; every arrival pill raised
/// inside it is counted here instead of getting a top pill and a sound of
/// its own, and the first one puts up a single bottom pill, with one sound,
/// pointing at the Vault. Tapping it opens the Vault. Once the window closes,
/// arrivals get the ordinary top pill again (`docs/pills.md`).
@MainActor
final class ReturnPillManager: ObservableObject {
    static let shared = ReturnPillManager()
    private init() {}

    @Published private(set) var summary = ReturnSummary()
    @Published private(set) var isShowing = false

    private var window: ReturnWindow?
    private var hideTask: Task<Void, Never>?

    /// How an arrival pill went.
    enum Gathered {
        /// Not gathering: show the ordinary top pill.
        case no
        /// Counted, and it is the first: play the one sound.
        case first
        /// Counted, silently.
        case added
    }

    /// The app is back from the background (or has just launched): start
    /// gathering. A pill still up from the last return goes.
    func beginReturn(now: Date = Date()) {
        hideTask?.cancel()
        window = ReturnWindow(returnedAt: now)
        summary = ReturnSummary()
        setShowing(false)
    }

    /// The app left the foreground: nothing more is gathered into a pill
    /// nobody can see.
    func endReturn() {
        hideTask?.cancel()
        window = nil
        setShowing(false)
    }

    /// Called for every arrival pill before it is drawn. `createdAt` is
    /// the event's own time, when known (see `ReturnWindow.arrive`).
    func gather(type: String, key: String, createdAt: Date? = nil, now: Date = Date()) -> Gathered {
        guard var w = window, w.arrive(at: now, createdAt: createdAt) else { return .no }
        window = w
        let first = summary.isEmpty
        // The folded strangers' alert keeps one id however many follow, and
        // each call is one more stranger, so each counts.
        summary.add(type: type, key: type == "followers" ? UUID().uuidString : key)
        if !isShowing {
            // First, or a late one bringing the pill back (silently).
            setShowing(true)
            #if os(iOS)
            // The full tab bar, so the Vault tab is there to point at.
            ChromeCollapse.shared.reset()
            #endif
        }
        scheduleHide(now: now)
        return first ? .first : .added
    }

    /// The pill was tapped: open the Vault's "Vault" list, everything new.
    func open() {
        endReturn()
        NotificationCenter.default.post(name: .havenOpenVault, object: nil)
    }

    private func scheduleHide(now: Date) {
        guard let until = window?.showsUntil else { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSince(now))))
            guard !Task.isCancelled else { return }
            self?.setShowing(false)
        }
    }

    private func setShowing(_ showing: Bool) {
        guard showing != isShowing else { return }
        withAnimation(Motion.bannerIn) { isShowing = showing }
        if !showing { FloatingButtonRow.shared.setLift(0) }
    }
}
