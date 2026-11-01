import SwiftUI

// MARK: - Feed Tab Hold Picker

/// The Feed tab: tap for the feed, press and hold, slide onto a feed and let
/// go to switch to it (`DockHoldMenu`). Closest to the finger first: the menu
/// grows upward from the tab, so the first feed in the reader's order (Edit
/// Feeds) sits right above it. Hidden feeds are left out.
struct FeedTabHoldItem: View {
    let selected: Bool
    @ObservedObject var feedService: FeedService
    let onTap: () -> Void

    var body: some View {
        DockHoldButton(onTap: onTap, entries: entries, onPick: pick) {
            VStack(spacing: 4) {
                Image(systemName: "person.2.wave.2")
                    .font(.appSystem(size: 20, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.havenPurple : .white)
                    .frame(height: 24)
                Text("Feed")
                    .font(.appSystem(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.havenPurple : .white)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Feed")
        .accessibilityValue(feedService.feedMode.displayName)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Hold to pick a feed")
        .accessibilityAction { onTap() }
        .accessibilityActions {
            ForEach(FeedMode.menuModes, id: \.self) { mode in
                Button(mode.displayName) { select(mode) }
            }
        }
    }

    private func entries() -> [DockHoldEntry] {
        FeedMode.menuModes.map {
            DockHoldEntry(id: $0.rawValue, title: $0.displayName, symbol: $0.symbolName,
                          isCurrent: $0 == feedService.feedMode)
        }
    }

    private func pick(_ id: String) {
        guard let mode = FeedMode.menuModes.first(where: { $0.rawValue == id }) else { return }
        select(mode)
    }

    private func select(_ mode: FeedMode) {
        if mode != feedService.feedMode { feedService.switchMode(mode) }
        if !selected { onTap() }
    }
}
