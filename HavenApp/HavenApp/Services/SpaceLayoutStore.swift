import Foundation
import Combine

/// The active account's rail pins and Your space panels (`SpaceLayout`,
/// docs/SPACE_LAYOUT.md). Kept on this device only, per account: every edit
/// is saved here at once. Nothing is signed, encrypted or sent to relays for
/// it (the kind 30078 sync was removed, Logen 2026-11-05).
@MainActor
final class SpaceLayoutStore: ObservableObject {
    static let shared = SpaceLayoutStore()

    /// The sections the iPad rail has, in the format's default order.
    static let railSections = ["feed", "search", "profile", "wot", "vault"]
    /// Your space's panels on the iPad, in the default order. Same ids as the web's panels.js.
    static let panelIds = ["live-vault", "wot-mini", "messages", "my-devices", LiveNow.panelId, "on-this-day"]

    @Published private(set) var layout: SpaceLayout = .defaultLayout(panelIds: SpaceLayoutStore.panelIds)

    private var owner = ""
    private var cancellables = Set<AnyCancellable>()

    static func key(_ owner: String) -> String { "nv-space-layout:\(owner)" }

    private init() {
        // The account itself, not `$config`: that fires in willSet, while the
        // active key still names the account being left.
        ConfigService.shared.$activeAccountHexPubkey
            .map { $0.lowercased() }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] hex in self?.attach(hex) }
            .store(in: &cancellables)
    }

    // MARK: Account

    private func attach(_ hex: String) {
        guard hex != owner else { return }
        owner = hex
        layout = Self.readLocal(hex) ?? .defaultLayout(panelIds: Self.panelIds)
    }

    private static func readLocal(_ hex: String) -> SpaceLayout? {
        guard !hex.isEmpty, let data = UserDefaults.standard.data(forKey: key(hex)) else { return nil }
        return SpaceLayout.decode(data, sections: railSections, panelIds: panelIds)
    }

    // MARK: Edits

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    /// Applies an edit: drawn at once and saved on the device.
    func edit(_ change: (SpaceLayout, Int64) -> SpaceLayout?) {
        guard let next = change(layout, now), next != layout else { return }
        layout = next
        saveLocal()
    }

    func setPanel(_ id: String, on: Bool? = nil, open: Bool? = nil) {
        edit { $0.settingPanel(id, on: on, open: open, at: $1) }
    }

    /// `ids`: the panels this screen draws, so up and down never swap with one
    /// it doesn't show.
    func movePanel(_ id: String, by delta: Int, ids: [String] = panelIds) {
        edit { $0.movingPanel(id, by: delta, ids: ids, at: $1) }
    }

    func resetPanels() { edit { $0.resettingPanels(panelIds: Self.panelIds, at: $1) } }

    /// False when it is already pinned or the rail is full.
    @discardableResult
    func addPin(_ pin: SpaceLayout.Pin) -> Bool {
        guard layout.addingPin(pin, at: now) != nil else { return false }
        edit { $0.addingPin(pin, at: $1) }
        return true
    }

    func removePin(_ id: String) { edit { $0.removingPin(id, at: $1) } }

    func movePins(from source: IndexSet, to destination: Int) {
        edit { $0.movingPins(from: source, to: destination, sections: Self.railSections, at: $1) }
    }

    func isPinned(_ kind: SpaceLayout.Pin.Kind) -> Bool {
        guard let pin = SpaceLayout.Pin.favourite(kind) else { return false }
        return layout.pins.contains { $0.id == pin.id }
    }

    private func saveLocal() {
        guard !owner.isEmpty else { return }
        UserDefaults.standard.set(layout.encoded(), forKey: Self.key(owner))
    }
}
