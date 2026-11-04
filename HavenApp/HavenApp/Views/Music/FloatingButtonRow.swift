import AVKit
import Combine
import SwiftUI

// MARK: - Floating button row

/// Shares the row above the iPhone tab bar between the mini player and the
/// screen's floating button (Post, Blossom, Relay). Each floating button
/// reports its width here; the mini player stops short of it, with a gap,
/// and the button always sits level with where the mini player goes, so the
/// mini player closing never moves it (Logen, 2026-10-05).
@MainActor
final class FloatingButtonRow: ObservableObject {
    static let shared = FloatingButtonRow()
    static let buttonHeight: CGFloat = 48
    /// Where a floating button sits before the tab bar has been measured.
    static let defaultBottom: CGFloat = 90
    static let trailingInset: CGFloat = 20
    static let gap: CGFloat = 10

    /// Space the mini player leaves on its right: the visible button's
    /// width, its trailing inset and the gap. Zero when no button is showing.
    @Published private(set) var reservedWidth: CGFloat = 0
    /// Bottom padding for floating buttons, from the bottom safe area:
    /// level with the mini player's spot, whether or not it's showing.
    @Published private(set) var buttonBottom: CGFloat = defaultBottom
    /// Extra room under floating buttons while the return pill sits in
    /// their row (`ReturnPillLayer`); 0 otherwise.
    @Published private(set) var lift: CGFloat = 0
    /// The tab bar and the mini player above it, together; 0 where there is
    /// no iPhone tab bar. The return pill sits on top of this.
    @Published private(set) var chromeHeight: CGFloat = 0
    /// The part of the dock already inside the screens' bottom safe area
    /// (the root's band, for picture-in-picture; `DockClearance`). Anything
    /// placed from that edge takes it off, or it sits a whole dock too high.
    @Published private(set) var band: CGFloat = 0

    private var widths: [UUID: CGFloat] = [:]
    private var keyboardUp = false
    private var keyboardObservers: [NSObjectProtocol] = []

    init() {
        #if os(iOS)
        // The dock leaves the root's safe area while the keyboard is up
        // (`DockInset.placement`), on the same notifications the dock uses.
        let center = NotificationCenter.default
        keyboardObservers = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setKeyboardUp(true) }
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setKeyboardUp(false) }
            },
        ]
        #endif
    }

    /// What is left of `height` (the dock, or part of it) to clear by hand.
    func clearing(_ height: CGFloat) -> CGFloat {
        DockClearance.remaining(height, band: band)
    }

    func report(_ id: UUID, width: CGFloat?) {
        widths[id] = width
        let widest = widths.values.max() ?? 0
        reservedWidth = widest > 0 ? widest + Self.trailingInset + Self.gap : 0
    }

    func update(tabBarOnlyHeight: CGFloat) {
        // The mini player sits 6pt above the tab bar (the inset's spacing).
        buttonBottom = tabBarOnlyHeight > 0
            ? tabBarOnlyHeight + 6
            : Self.defaultBottom
    }

    func update(chromeHeight: CGFloat) {
        if self.chromeHeight != chromeHeight { self.chromeHeight = chromeHeight }
        updateBand()
    }

    private func setKeyboardUp(_ up: Bool) {
        keyboardUp = up
        updateBand()
    }

    private func updateBand() {
        let band = DockClearance.band(dockHeight: chromeHeight, keyboardUp: keyboardUp)
        if self.band != band { self.band = band }
    }

    func setLift(_ lift: CGFloat) {
        if self.lift != lift { self.lift = lift }
    }
}

/// Places a floating button (Post, Blossom, Relay) in the row above the tab
/// bar and reports its width so the mini player can make room for it.
///
/// Where there is no iPhone tab bar (the iPad split, macOS) there's no row to
/// share: the button sits at the ordinary 20pt margin and reports nothing.
struct FloatingButtonSlot: ViewModifier {
    @ObservedObject private var row = FloatingButtonRow.shared
    @Environment(\.floatingTabBarHeight) private var tabBarHeight
    @State private var id = UUID()

    func body(content: Content) -> some View {
        let sharesRow = tabBarHeight > 0
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { if sharesRow { row.report(id, width: geo.size.width) } }
                        .onChange(of: geo.size.width) { _, width in if sharesRow { row.report(id, width: width) } }
                }
            )
            .onDisappear { row.report(id, width: nil) }
            .padding(.trailing, FloatingButtonRow.trailingInset)
            // From the safe area's bottom, which already holds the dock's
            // band; level with the mini player either way.
            .padding(.bottom, sharesRow ? row.buttonBottom + row.lift - row.band : 20)
            .animation(Motion.chrome, value: row.buttonBottom)
            .animation(Motion.chrome, value: row.lift)
    }
}

/// Docks the mini player at the bottom of a screen when no iPhone tab bar
/// is carrying it (`floatingTabBarHeight` is 0 on iPad and Mac).
struct MiniPlayerInset: ViewModifier {
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if tabBarHeight == 0 {
                MiniPlayerBar().padding(.bottom, 10)
            }
        }
    }
}
