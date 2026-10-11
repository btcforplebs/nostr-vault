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

    private var widths: [UUID: CGFloat] = [:]

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
            .padding(.bottom, sharesRow ? row.buttonBottom : 20)
            .animation(Motion.chrome, value: row.buttonBottom)
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
