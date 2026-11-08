import Foundation

/// Settings › Media Servers as an unsaved draft (Logen via Tod, 2026-11-08).
/// Adding or removing a typed server, a suggested one, or a vault under
/// "Your Vaults on the Mesh" only changes the list on screen. Save writes the
/// typed servers and publishes the media server list (kind 10063) once;
/// leaving with unsaved changes asks Save or Discard. Same rule as
/// Settings › Relays (`RelayDraft`).
struct MediaServersDraft: Equatable {
    /// The typed servers when the screen opened, or at the last Save.
    private(set) var savedMirrors: [String]
    /// The typed servers on screen.
    private(set) var mirrors: [String]
    /// Mesh entries (`fipsmesh://<npub>/`) to add to / take off the published list.
    private(set) var meshAdd: [String] = []
    private(set) var meshRemove: [String] = []
    /// Mesh changes already saved, shown until the published list shows them
    /// (or the view gives up waiting): npub entry → wanted listed.
    private(set) var awaitingPublish: [String: Bool] = [:]

    init(mirrors: [String]) {
        savedMirrors = mirrors
        self.mirrors = mirrors
    }

    var hasChanges: Bool { changeCount > 0 }

    /// Servers added or removed, plus mesh vaults added or removed.
    var changeCount: Int {
        let saved = Set(savedMirrors), now = Set(mirrors)
        return now.subtracting(saved).count + saved.subtracting(now).count + meshAdd.count + meshRemove.count
    }

    /// "https://" in front when no scheme was typed, no trailing slash.
    /// Nil for an empty entry.
    static func normalized(_ typed: String) -> String? {
        var trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if !lower.hasPrefix("https://") && !lower.hasPrefix("http://") {
            trimmed = "https://" + trimmed
        }
        while trimmed.hasSuffix("/") { trimmed = String(trimmed.dropLast()) }
        return trimmed
    }

    /// Adds a typed or suggested server to the list on screen. False when it
    /// was empty or already there.
    @discardableResult
    mutating func addMirror(_ typed: String) -> Bool {
        guard let url = Self.normalized(typed), !mirrors.contains(url) else { return false }
        mirrors.append(url)
        return true
    }

    mutating func removeMirror(_ url: String) {
        mirrors.removeAll { $0 == url }
    }

    /// Whether a mesh row shows as listed: the unsaved change, else a saved
    /// one still on its way, else the published list.
    func shownListed(_ entry: String, published: Bool) -> Bool {
        if meshAdd.contains(entry) { return true }
        if meshRemove.contains(entry) { return false }
        return awaitingPublish[entry] ?? published
    }

    /// Add or Remove on a mesh row. `published` is whether the published list
    /// has it now; undoing a change before Save leaves nothing to publish.
    mutating func setMesh(_ entry: String, listed: Bool, published: Bool) {
        meshAdd.removeAll { $0 == entry }
        meshRemove.removeAll { $0 == entry }
        let current = awaitingPublish[entry] ?? published
        guard listed != current else { return }
        if listed { meshAdd.append(entry) } else { meshRemove.append(entry) }
    }

    /// What Save hands the publisher: the typed servers to store, and the
    /// mesh entries to add and take off. One publish carries all of it.
    struct SavePlan: Equatable {
        let mirrors: [String]
        let mirrorsChanged: Bool
        let meshAdd: [String]
        let meshRemove: [String]
    }

    var savePlan: SavePlan {
        SavePlan(mirrors: mirrors, mirrorsChanged: mirrors != savedMirrors, meshAdd: meshAdd, meshRemove: meshRemove)
    }

    /// After Save: the screen's list is the saved list, and the mesh changes
    /// wait for the published list to show them.
    mutating func didSave() {
        savedMirrors = mirrors
        for entry in meshAdd { awaitingPublish[entry] = true }
        for entry in meshRemove { awaitingPublish[entry] = false }
        meshAdd = []
        meshRemove = []
    }

    /// Discard: back to the saved list, nothing to publish.
    mutating func discard() {
        mirrors = savedMirrors
        meshAdd = []
        meshRemove = []
    }

    /// The published list changed (or the wait ran out): show it as it is.
    mutating func publishedListChanged() {
        awaitingPublish = [:]
    }

    /// The typed servers changed elsewhere (another device's list adopted):
    /// follow them unless there are unsaved edits here.
    mutating func savedMirrorsChanged(_ mirrors: [String]) {
        guard !hasChanges else { return }
        savedMirrors = mirrors
        self.mirrors = mirrors
    }

    static func changesLabel(_ count: Int) -> String {
        count == 1 ? "1 change" : "\(count) changes"
    }
}
