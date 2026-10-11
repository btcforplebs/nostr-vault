import SwiftUI

#if os(iOS)
/// The feed picker in the top-left of the feed. Equatable on the values it
/// shows, so it does not rebuild for unrelated FeedService changes while open.
struct FeedPickerMenu: View, Equatable {
    let mode: FeedMode
    let connectionStatus: String
    let isCompactWidth: Bool
    /// The feeds to list, in the reader's order.
    let modes: [FeedMode]
    let onSelect: (FeedMode) -> Void
    let onEdit: () -> Void
    let onDashboard: () -> Void

    static func == (lhs: FeedPickerMenu, rhs: FeedPickerMenu) -> Bool {
        lhs.mode == rhs.mode
            && lhs.modes == rhs.modes
            && lhs.connectionStatus == rhs.connectionStatus
            && lhs.isCompactWidth == rhs.isCompactWidth
    }

    var body: some View {
        Menu {
            Picker(selection: Binding(
                get: { mode },
                set: { onSelect($0) }
            )) {
                ForEach(modes, id: \.self) { mode in
                    Label(mode.displayName, systemImage: mode.symbolName)
                        .tag(mode)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)

            Divider()

            // Your network's day. Activity only; feed settings are in Settings > Feed.
            Button(action: onDashboard) {
                Label("Dashboard", systemImage: "square.grid.2x2")
            }

            // Last, at the bottom of the list it edits.
            Button(action: onEdit) {
                Label("Edit Feeds", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 0) {
                // No glass ring of its own: glassEffect takes touches even
                // with hit testing off, which left the icon the one spot that
                // did not open the menu. Folded, the pill itself is the ring.
                Image(systemName: mode.symbolName)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)

                // Always laid out, only faded: removing it would resize the
                // toolbar item and make the navigation bar relayout mid-fold.
                ChromeFold(anchor: .leading, isEnabled: isCompactWidth) {
                    HStack(spacing: 3) {
                        Text(mode.displayName)
                            .font(.appSystem(size: 17, weight: .bold))
                        Image(systemName: "chevron.down")
                            .font(.appSystem(size: 9, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.leading, 8)
                    .padding(.trailing, 12)
                }
            }
            .padding(.leading, 7)
            .padding(.vertical, 7)
            // The toolbar proposes a narrow width; without this the feed
            // name truncates away and only the icon and chevron are left.
            .fixedSize()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Feed: \(mode.displayName)")
        .accessibilityValue(connectionStatus)
        .accessibilityHint("Switch feeds or open the feed dashboard")
    }
}
#endif
