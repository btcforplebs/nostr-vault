import SwiftUI

// MARK: - Vault Tab Hold Picker

/// The Vault tab: tap for the tab, press and hold, slide onto a page (Vault,
/// Notes, Media, ...) and let go to open it (`DockHoldMenu`). The same pages,
/// in the same order, as the Vault mode pill, with its red dots.
struct VaultTabHoldItem<Label: View>: View {
    let selected: Bool
    let zapsOnly: Bool
    @ObservedObject var relayManager: RelayProcessManager
    /// Puts the Vault tab on screen (the tab's own tap when it isn't).
    let onTap: () -> Void
    @ViewBuilder let label: () -> Label

    @ObservedObject private var section = VaultSection.shared

    private var modes: [VaultMode] {
        VaultMode.allCases.filter { !(zapsOnly && $0 == .likes) }
    }

    private var current: VaultMode { section.showsMedia ? .media : section.listMode }

    var body: some View {
        DockHoldButton(onTap: onTap, entries: entries, onPick: pick, label: label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Vault")
            .accessibilityValue(current.title)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint("Hold to pick a Vault page")
            .accessibilityAction { onTap() }
            .accessibilityActions {
                ForEach(modes, id: \.self) { mode in
                    Button(mode.title) { open(mode) }
                }
            }
    }

    private func entries() -> [DockHoldEntry] {
        let news = section.newModes.union(relayManager.newActivityModes)
        return modes.map {
            DockHoldEntry(id: $0.rawValue, title: $0.title, symbol: $0.symbol,
                          isCurrent: $0 == current, hasNews: news.contains($0))
        }
    }

    private func pick(_ id: String) {
        guard let mode = VaultMode(rawValue: id) else { return }
        open(mode)
    }

    /// The Vault list applies the page once it is built: on a first visit
    /// it doesn't exist yet to hear `VaultMode.select()` directly.
    private func open(_ mode: VaultMode) {
        section.pendingMode = mode
        if !selected { onTap() }
    }
}
