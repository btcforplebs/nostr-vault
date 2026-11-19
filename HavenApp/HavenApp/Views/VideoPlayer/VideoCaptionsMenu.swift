import SwiftUI
import AVFoundation

/// Captions and subtitles the clip carries (its legible media group), with
/// Off. Not drawn when the clip has none, which is most uploaded clips.
struct VideoCaptionsMenu: View {
    let player: AVPlayer
    var onInteract: (() -> Void)? = nil

    @State private var group: AVMediaSelectionGroup?
    @State private var selected: AVMediaSelectionOption?

    var body: some View {
        Group {
            if let group, !group.options.isEmpty {
                Menu {
                    if group.allowsEmptySelection {
                        Button { choose(nil, in: group) } label: { checked("Off", selected == nil) }
                    }
                    ForEach(group.options, id: \.self) { option in
                        Button { choose(option, in: group) } label: {
                            checked(option.displayName, selected == option)
                        }
                    }
                } label: {
                    Image(systemName: selected == nil ? "captions.bubble" : "captions.bubble.fill")
                        .font(.appSystem(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("Captions")
            }
        }
        .task(id: player.currentItem.map(ObjectIdentifier.init)) {
            await load()
        }
    }

    @ViewBuilder
    private func checked(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func choose(_ option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup) {
        onInteract?()
        player.currentItem?.select(option, in: group)
        selected = option
    }

    private func load() async {
        guard let item = player.currentItem,
              let legible = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
            group = nil
            return
        }
        group = legible
        selected = item.currentMediaSelection.selectedMediaOption(in: legible)
    }
}
