import SwiftUI

/// One list entry in a Restore or Merge preview: a person as picture + name
/// (never hex; a short npub only while the name loads), anything else as its
/// text. Web (`RecoverListPage.jsx` EntryRow) and Android show people the
/// same way.
struct ListEntryLabel: View {
    let key: String
    var note: String?
    @ObservedObject private var nostr = NostrService.shared

    var body: some View {
        HStack(spacing: 10) {
            if let hex = ListVersionWording.person(key) {
                let profile = nostr.profiles[hex]
                AvatarView(url: profile?.pictureURL, pubkey: hex, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.map(\.bestName) ?? Self.shortNpub(hex)).lineLimit(1)
                    if let note { Text(note).font(.appCaption).foregroundColor(.secondary) }
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ListHistory.label(key)).font(.appCaption).lineLimit(1).truncationMode(.middle)
                    if let note { Text(note).font(.appCaption).foregroundColor(.secondary) }
                }
            }
        }
    }

    static func shortNpub(_ hex: String) -> String {
        guard let npub = ProfileRepository.hexKeysToNpubs([hex]).first else { return "Someone" }
        return String(npub.prefix(9)) + "…" + String(npub.suffix(4))
    }

    /// Ask for the names and pictures of the people among `keys` (the first
    /// `limit`, the ones the screen shows).
    static func loadPeople(_ keys: some Sequence<String>, limit: Int = 500) {
        let hexes = keys.lazy.compactMap(ListVersionWording.person).prefix(limit)
        NostrService.shared.fetchMissingProfiles(for: Array(hexes))
    }
}
