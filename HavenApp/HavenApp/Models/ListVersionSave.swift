import Foundation

/// What ListVersionSave needs to know about a list event.
protocol ListVersionSaveEvent {
    var id: String { get }
    var pubkey: String { get }
    var created_at: Int64 { get }
}

/// One safe save for a new version of a list (twin of Android ListVersionSave.kt,
/// RESEARCH/NV_LIST_PROTECTION_PLAN.md, RESEARCH/NV_EMOJI_LIST_HISTORY_AUDIT.md):
/// 1. the newest list is fetched again (and, when `shownId` is given, must be the one shown);
/// 2. the vault must hold that newest list first, so the change can be undone; if it can't, nothing is signed;
/// 3. the new tags are signed by the list's account, dated after the newest;
/// 4. the vault must accept the new version, and only then does it go to the account's relays.
/// `Steps` does the network and signing; this decides. Pure for the tests.
enum ListVersionSave {
    struct Failure: Error, Equatable { let message: String }

    struct Steps<Event: ListVersionSaveEvent> {
        /// The active account's hex pubkey right now.
        var activeAccount: () -> String
        /// The newest copy of the list, by the rule every list edit uses; a failure carries what to tell the person.
        var newest: () async -> Result<Event?, Failure>
        /// Whether the vault holds `current` (already, or once sent to it).
        var keepUndoCopy: (Event) async -> Bool
        /// Signs as the list's account, dated `notBefore` or later; nil when it can't.
        var sign: (_ kind: Int, _ content: String, _ tags: [[String]], _ notBefore: Int64) async -> Event?
        /// Whether the vault accepted the new version.
        var store: (Event) async -> Bool
        /// Sends the new version to the account's relays.
        var send: (Event) async -> Void
    }

    enum Build {
        case ready(tags: [[String]], content: String)
        /// Nothing to change: no new version is signed.
        case unchanged
        case refuse(String)
    }

    enum Outcome<Event> {
        case saved(Event)
        /// Nothing new was signed; `current` is the newest list as it is.
        case unchanged(current: Event?)
        /// `changed`: the list changed since it was shown.
        case refused(String, changed: Bool = false)
    }

    /// Saves a new version of `pubkey`'s `kind` list. `shownId`: nil skips the check; `.some(nil)` means the
    /// person was shown no list. `verb` names the action in messages ("change", "save").
    static func save<Event: ListVersionSaveEvent>(
        _ steps: Steps<Event>, pubkey: String, kind: Int, shownId: String?? = nil, verb: String,
        now: Int64 = Int64(Date().timeIntervalSince1970),
        build: (Event?) async -> Build
    ) async -> Outcome<Event> {
        let name = ListShrinkRule.name(kind)
        let current: Event?
        switch await steps.newest() {
        case .failure(let failure): return .refused(failure.message)
        case .success(let event): current = event
        }
        if let shownId, current?.id != shownId {
            return .refused("Your \(name) changed while this was open. Nothing was changed; look again and retry.", changed: true)
        }
        let tags: [[String]], content: String
        switch await build(current) {
        case .refuse(let message): return .refused(message)
        case .unchanged: return .unchanged(current: current)
        case .ready(let t, let c): (tags, content) = (t, c)
        }
        if let current, !(await steps.keepUndoCopy(current)) {
            return .refused("Your vault couldn't keep a copy of your newest \(name), so the \(verb) couldn't be undone. Nothing was changed.")
        }
        guard let signed = await steps.sign(kind, content, tags, ListMerge.signedAt(now: now, base: current?.created_at)),
              signed.pubkey == pubkey else {
            return .refused("The list couldn't be signed. Nothing was changed.")
        }
        guard steps.activeAccount() == pubkey else {
            return .refused("You switched accounts during the \(verb). Nothing was changed.")
        }
        guard await steps.store(signed) else {
            return .refused("Your vault refused the \(pastTense(verb)) \(name). Nothing was sent to your relays.")
        }
        // send goes through the active account's relays: still this one?
        guard steps.activeAccount() == pubkey else {
            return .refused("You switched accounts during the \(verb). Your vault kept the \(pastTense(verb)) list; this app didn't send it to your relays. Switch back and check it.")
        }
        await steps.send(signed)
        return .saved(signed)
    }

    private static func pastTense(_ verb: String) -> String {
        verb.hasSuffix("e") ? verb + "d" : verb + "ed"
    }
}
