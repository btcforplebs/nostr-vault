import Foundation

/// Kind 10000 edits (blocks and muted words) run one at a time: each waits
/// for the one before it to finish before it looks up the list. Two at once
/// would both build on the same list, and whichever was signed last would
/// drop the other's change while both showed success (Tron #2663 F1).
@MainActor
enum MuteListEdits {
    private static var last: Task<Void, Never>?

    static func run(_ edit: @escaping @MainActor () async -> Void) {
        let previous = last
        last = Task { @MainActor in
            await previous?.value
            await edit()
        }
    }
}

extension NostrService {
    /// What an edit of `author`'s kind 10000 builds on: the newest list from
    /// the relays it is read from at launch, so an edit builds on the list
    /// another app last wrote, not an older copy. With no list anywhere, the
    /// `localBlocks` (hex) as `p` tags. Nil when the list can't be known: the
    /// person is told why, starting with `notSaved`, and nothing is published.
    /// Used by blocks (`publishMuteListChange`) and muted words.
    @MainActor
    func muteListEditBase(author: String, localBlocks: [String],
                          notSaved: String) async -> (base: (tags: [[String]], content: String), baseAt: Int64?)? {
        let alsoAsk = Array(Set(ConfigService.shared.config.readRelays + MuteListStore.extraRelays))
        let lookup = await lookupNewestReplaceable(kind: 10000, for: author, alsoAsk: alsoAsk, skipAhead: true)
        switch ListMerge.editBase(lookup, held: MuteListStore.shared.storedEvent(forHex: author),
                                  own: Self.ownListRelays(for: author), createdAt: { $0.created_at }) {
        case .list(let event):
            return ((event.tags, event.content), event.created_at)
        case .none:
            return ((localBlocks.map { ["p", $0] }, ""), nil)
        case .noRelayList:
            ActionToastManager.shared.show(icon: "exclamationmark.triangle.fill",
                                           message: "\(notSaved). \(ListMerge.noRelayListMessage)",
                                           tone: .error)
            return nil
        case .unknown:
            #if DEBUG
            print("NostrService: Kind 10000: list not fetched (\(lookup.answered)/\(lookup.asked) relays answered); not published")
            #endif
            ActionToastManager.shared.show(
                icon: "exclamationmark.triangle.fill",
                message: "\(notSaved): your relays didn't send your mute list, and publishing without it would erase blocks set in other apps. Try again later.",
                tone: .error)
            return nil
        }
    }
}
