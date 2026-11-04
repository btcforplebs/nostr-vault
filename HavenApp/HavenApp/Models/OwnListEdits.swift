import Foundation

/// The ids of list events Nostr Vault signed on this device, so the wipe
/// alarm never fires for the owner's own edit (docs/LIST_WIPE_ALARM.md).
/// Every signature goes through NostrService.signEvent / signEventAsync,
/// which note it here. Only protected list kinds are kept, newest 500.
enum OwnListEdits {
    static let key = "ownListEditIds"
    static let cap = 500

    @discardableResult
    static func noting(_ event: NostrEvent?) -> NostrEvent? {
        if let event, ListShrinkRule.isProtected(event.kind) { record(event.id) }
        return event
    }

    static func record(_ id: String, defaults: UserDefaults = .standard) {
        var list = defaults.stringArray(forKey: key) ?? []
        guard !list.contains(id) else { return }
        list.append(id)
        if list.count > cap { list.removeFirst(list.count - cap) }
        defaults.set(list, forKey: key)
    }

    static func ids(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
}
