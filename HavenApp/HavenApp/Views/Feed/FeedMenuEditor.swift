import SwiftUI

// MARK: - Feed picker editor

/// Show, hide and reorder the feeds in the feed picker. Following is the
/// home feed, so it is always shown. Hiding the feed you're on takes you
/// back to Following.
struct FeedMenuEditor: View {
    let onDismiss: () -> Void
    @AppStorage(FeedMode.menuOrderKey) private var orderRaw = ""
    @AppStorage(FeedMode.menuHiddenKey) private var hiddenRaw = ""
    @State private var order: [FeedMode] = []
    @State private var hidden: Set<FeedMode> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order, id: \.self) { mode in
                        row(mode)
                    }
                    .onMove { from, to in
                        order.move(fromOffsets: from, toOffset: to)
                        save()
                    }
                } footer: {
                    Text("Tap a feed to show or hide it. Drag to change the order. Following is always shown.")
                }
                Section {
                    Button("Reset to Default") {
                        order = FeedMode.allCases
                        hidden = []
                        save()
                    }
                    .disabled(order == FeedMode.allCases && hidden.isEmpty)
                }
            }
            #if os(iOS)
            // Always reorderable: the drag handles are the point of this screen.
            .environment(\.editMode, .constant(.active))
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("Edit Feeds")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .onAppear {
            order = FeedMode.menuOrder(orderRaw)
            hidden = Set(FeedMenuOrder.decode(hiddenRaw).compactMap(FeedMode.init(rawValue:)))
        }
    }

    private func row(_ mode: FeedMode) -> some View {
        let isPinned = mode == .following
        let isShown = isPinned || !hidden.contains(mode)
        return Button {
            guard !isPinned else { return }
            if isShown { hidden.insert(mode) } else { hidden.remove(mode) }
            save()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isShown ? "checkmark.circle.fill" : "circle")
                    .font(.appSystem(size: 20))
                    .foregroundColor(isShown ? (isPinned ? .secondary : .havenPurple) : .secondary)
                Image(systemName: mode.symbolName)
                    .font(.appSystem(size: 16, weight: .semibold))
                    .foregroundColor(isShown ? .havenPurple : .secondary)
                    .frame(width: 24)
                Text(mode.displayName)
                    .foregroundColor(isShown ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(mode.displayName))
        .accessibilityValue(Text(isShown ? "Shown" : "Hidden"))
        .accessibilityHint(isPinned ? Text("Always shown") : Text("Shows or hides this feed"))
    }

    private func save() {
        orderRaw = order == FeedMode.allCases ? "" : FeedMenuOrder.encode(order.map(\.rawValue))
        hiddenRaw = FeedMenuOrder.encode(order.filter { hidden.contains($0) }.map(\.rawValue))
        // Hiding the feed you're on would leave the picker without it.
        let feedService = FeedService.shared
        if hidden.contains(feedService.feedMode) { feedService.switchMode(.following) }
    }
}
