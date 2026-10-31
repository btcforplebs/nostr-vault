import Foundation

/// Settings > Relays as an unsaved draft (Logen 2026-10-31, option A). Mirrors
/// Android `relay/RelayDraft.kt`.
///
/// Nothing is written or published until Save. Rows come in two sections:
/// "Yours", the relays on the owner's published relay list (kind 10002) and
/// DM inbox (kind 10050) plus any added here, and "App defaults", everything
/// else the app put in the lists. Save publishes only the Yours rows; App
/// defaults stay on this device. Search and Import are never published.
///
/// The row order is fixed when the screen opens: tapping dots, removing and
/// saving never move a row. Only an explicit add puts a row at the end of Yours.
enum RelayDraft {
    typealias Job = RelayMatrix.Job
    typealias Lists = RelayMatrix.Lists

    enum Section: Equatable { case yours, defaults }

    struct Entry: Equatable, Identifiable {
        let key: String
        let url: String
        var section: Section
        var id: String { key }
    }

    /// The owner's published lists. `relayListKnown` / `dmListKnown` are false
    /// when the relays didn't settle whether one exists: publishing then could
    /// replace a list set in another app, so Save keeps the change on this device.
    struct Published: Equatable {
        var read: [String] = []
        var write: [String] = []
        var dms: [String] = []
        var relayListKnown = false
        var dmListKnown = false
        /// Published 10002 tags this screen can't show or edit (ws://, home
        /// network, .local, CGNAT, .ts.net). Save carries them through as
        /// published, so editing one relay never drops another app's entries.
        var kept: [[String]] = []
        /// False during setup, before the new key is stored: there is no
        /// list to load, and setup's own step publishes the first one.
        var hasAccount = true
    }

    /// Whether a relay can be a row of the published relay list: a wss://
    /// address others can reach. Anything else in a published list is `kept`.
    static func listable(_ url: String) -> Bool {
        !HavenConfig.publicRelayListTags(ownRelays: [url], read: [], write: []).isEmpty
    }

    /// The relays that index every account's lists; a "none" counts only when both answered.
    static let indexers = ["wss://purplepag.es", "wss://user.kindpag.es"]

    /// Whether a lookup settled the list: every one of the `indexers`
    /// answered, found or not. Any other relay answering proves little: most
    /// of them are this device's own defaults, a list made in another app may
    /// never have reached them, and one of them may hold an older copy that
    /// re-signing would bring back (Tron, #1386).
    static func settled(found: Bool, answeredBy: Set<String>) -> Bool {
        let answered = Set(answeredBy.map(RelayMatrix.key))
        return indexers.allSatisfy { answered.contains(RelayMatrix.key($0)) }
    }

    struct State: Equatable {
        /// The lists when the screen opened, or at the last Save.
        var start: Lists
        var draft: Lists
        var layout: [Entry]
        /// Removed rows (by key), with the jobs each had, for Undo.
        var removed: [String: Set<Job>]
        var published: Published
        /// App defaults added by hand since the last Save: now Yours.
        var moved: Set<String> = []

        var yours: Set<String> { Set(layout.filter { $0.section == .yours }.map(\.key)) }
    }

    struct Row: Equatable, Identifiable {
        let entry: Entry
        let jobs: Set<Job>
        let removed: Bool
        var id: String { entry.key }
        var url: String { entry.url }
        func has(_ job: Job) -> Bool { jobs.contains(job) }
    }

    /// The draft for `lists` (this device's config). The published relays
    /// join their jobs, so the screen shows the owner's real lists. `pinned`
    /// (the vault's own relay and inbox) has its own row and is left out.
    static func start(_ lists: Lists, published: Published, pinned: [String] = []) -> State {
        let pinnedKeys = Set(pinned.filter { !$0.isEmpty }.map(RelayMatrix.key))
        func join(_ job: Job, _ urls: [String], _ into: Lists) -> Lists {
            urls.filter { !HavenConfig.normalizedRelayURL($0).isEmpty && !pinnedKeys.contains(RelayMatrix.key($0)) }
                .reduce(into) { RelayMatrix.setting(job, true, for: $1, in: $0) }
        }
        let joined = join(.dms, published.dms, join(.write, published.write, join(.read, published.read, lists)))
        let theirs = Set((published.read + published.write + published.dms).map(RelayMatrix.key))
        // On their relays, Read, Write and DMs are what they published: a
        // default job the app also gave one of them would otherwise go out
        // with their list at the next Save.
        let publishedJobs: [(Job, Set<String>)] = [
            (.read, Set(published.read.map(RelayMatrix.key))),
            (.write, Set(published.write.map(RelayMatrix.key))),
            (.dms, Set(published.dms.map(RelayMatrix.key))),
        ]
        let draft = RelayMatrix.rows(joined, pinned: pinned).filter { theirs.contains($0.id) }.reduce(joined) { acc, row in
            publishedJobs.reduce(acc) { inner, pair in
                RelayMatrix.setting(pair.0, pair.1.contains(row.id), for: row.url, in: inner)
            }
        }
        let rows = RelayMatrix.rows(draft, pinned: pinned)
        let layout = rows.filter { theirs.contains($0.id) }.map { Entry(key: $0.id, url: $0.url, section: .yours) }
            + rows.filter { !theirs.contains($0.id) }.map { Entry(key: $0.id, url: $0.url, section: .defaults) }
        return State(start: draft, draft: draft, layout: layout, removed: [:], published: published)
    }

    static func rows(_ state: State) -> [Row] {
        state.layout.map { entry in
            let removed = state.removed[entry.key]
            return Row(entry: entry, jobs: removed ?? jobs(state.draft, entry.key), removed: removed != nil)
        }
    }

    static func jobs(_ lists: Lists, _ key: String) -> Set<Job> {
        Set(Job.allCases.filter { job in lists[job].contains { RelayMatrix.key($0) == key } })
    }

    /// Turns one job on or off. A removed row ignores taps until Undo.
    static func toggle(_ state: State, key: String, job: Job) -> State {
        guard let entry = state.layout.first(where: { $0.key == key }), state.removed[key] == nil else { return state }
        var next = state
        next.draft = RelayMatrix.setting(job, !jobs(state.draft, key).contains(job), for: entry.url, in: state.draft)
        return next
    }

    static func remove(_ state: State, key: String) -> State {
        guard let entry = state.layout.first(where: { $0.key == key }), state.removed[key] == nil else { return state }
        var next = state
        next.draft = RelayMatrix.removing(entry.url, from: state.draft)
        next.removed[key] = jobs(state.draft, key)
        return next
    }

    static func undo(_ state: State, key: String) -> State {
        guard let entry = state.layout.first(where: { $0.key == key }), let had = state.removed[key] else { return state }
        var next = state
        next.draft = had.reduce(state.draft) { RelayMatrix.setting($1, true, for: entry.url, in: $0) }
        next.removed[key] = nil
        return next
    }

    /// Adds `url` with `jobs`: a new row at the end of Yours. A relay already
    /// listed keeps its row and gets the jobs; an App default someone adds by
    /// hand becomes theirs and moves to the end of Yours.
    static func add(_ state: State, url: String, jobs added: Set<Job>) -> State {
        let k = RelayMatrix.key(url)
        guard !k.isEmpty else { return state }
        var s = state.removed[k] != nil ? undo(state, key: k) : state
        let existing = s.layout.first { $0.key == k }
        let spelling = existing?.url ?? HavenConfig.normalizedRelayURL(url)
        if let existing {
            if existing.section == .defaults {
                var mine = existing
                mine.section = .yours
                s.layout = s.layout.filter { $0.key != k } + [mine]
                s.moved.insert(k)
            }
        } else {
            s.layout.append(Entry(key: k, url: spelling, section: .yours))
        }
        // Fixed order: the same jobs always land in the same list order.
        s.draft = Job.allCases.filter(added.contains).reduce(s.draft) { RelayMatrix.setting($1, true, for: spelling, in: $0) }
        return s
    }

    /// Sets one job for a relay that may have no row of its own (the vault's
    /// relay, pinned at the top). A change shows up as kept on this device.
    static func setJob(_ state: State, url: String, job: Job, on: Bool) -> State {
        var next = state
        next.draft = RelayMatrix.setting(job, on, for: url, in: state.draft)
        return next
    }

    /// Search goes back to the app's `defaults`. Relays that had no row get
    /// one at the end of App defaults, so nothing already shown moves.
    static func resetSearch(_ state: State, defaults: [String], pinned: [String] = []) -> State {
        var next = state
        next.draft.search = defaults
        let known = Set(state.layout.map(\.key) + pinned.filter { !$0.isEmpty }.map(RelayMatrix.key))
        next.layout += RelayMatrix.rows(next.draft).filter { !known.contains($0.id) }
            .map { Entry(key: $0.id, url: $0.url, section: .defaults) }
        return next
    }

    /// Every relay in the start or the draft, first spelling kept: rows and pinned ones alike.
    private static func allRelays(_ state: State) -> [(key: String, url: String)] {
        var order: [String] = []
        var spelling: [String: String] = [:]
        func note(_ k: String, _ url: String) {
            guard !k.isEmpty, spelling[k] == nil else { return }
            spelling[k] = url
            order.append(k)
        }
        state.layout.forEach { note($0.key, $0.url) }
        for lists in [state.start, state.draft] {
            for job in Job.allCases {
                for url in lists[job] { note(RelayMatrix.key(url), HavenConfig.normalizedRelayURL(url)) }
            }
        }
        return order.map { ($0, spelling[$0]!) }
    }

    /// Relays whose jobs differ from `State.start`, counting a default made Yours as a change.
    static func changeCount(_ state: State) -> Int {
        allRelays(state).filter { jobs(state.draft, $0.key) != jobs(state.start, $0.key) || state.moved.contains($0.key) }.count
    }

    // MARK: - Save

    /// One line of the confirm sheet: a relay and the jobs it gains or loses.
    struct Change: Equatable, Identifiable {
        let url: String
        let added: Set<Job>
        let removed: Set<Job>
        var id: String { RelayMatrix.key(url) }
    }

    struct Plan: Equatable {
        /// Kind 10002 tags to publish, or nil when it isn't published.
        let relayListTags: [[String]]?
        let relayListChanges: [Change]
        /// The kind 10050 relays to publish, or nil when it isn't published.
        let dmRelays: [String]?
        let dmChanges: [Change]
        /// Changes kept on this device: App defaults, Search and Import.
        let localChanges: [Change]
        /// A Yours change that can't be published because the list wasn't loaded.
        let relayListHeld: Bool
        let dmListHeld: Bool

        var publishes: Bool { relayListTags != nil || dmRelays != nil }
    }

    private static func yoursOnly(_ list: [String], _ yours: Set<String>) -> [String] {
        list.filter { yours.contains(RelayMatrix.key($0)) }
    }

    private static func keys(_ list: [String]) -> Set<String> { Set(list.map(RelayMatrix.key)) }

    /// What Save does. Kind 10002 goes out only when a Yours row's Read or
    /// Write changed, kind 10050 only when a Yours row's DMs changed, and each
    /// holds the Yours rows alone (`ownRelays` and `ownInbox` lead, as before).
    static func plan(_ state: State, ownRelays: [String], ownInbox: String) -> Plan {
        let yours = state.yours
        let draft = state.draft
        let start = state.start
        let p = state.published

        let readNow = yoursOnly(draft.read, yours)
        let writeNow = yoursOnly(draft.write, yours)
        let relayListEdited = keys(readNow) != keys(yoursOnly(start.read, yours))
            || keys(writeNow) != keys(yoursOnly(start.write, yours))
            || movedAny(state, [.read, .write])
        let shown = HavenConfig.publicRelayListTags(ownRelays: ownRelays, read: readNow, write: writeNow)
        let shownKeys = Set(shown.map { RelayMatrix.key($0[1]) })
        let newTags = shown + p.kept.filter { !shownKeys.contains(RelayMatrix.key($0[1])) }
        let relayListChanges = relayListEdited
            ? diff(before: HavenConfig.publicRelayListTags(ownRelays: [], read: p.read, write: p.write) + p.kept, after: newTags)
            : []
        let publishRelayList = relayListEdited && p.relayListKnown && !relayListChanges.isEmpty

        let dmsNow = yoursOnly(draft.dms, yours)
        let dmEdited = keys(dmsNow) != keys(yoursOnly(start.dms, yours)) || movedAny(state, [.dms])
        let newDMs = HavenConfig.mergedDMInboxRelays(havenInbox: ownInbox, dmRelays: dmsNow)
            .filter { !HavenConfig.isPrivateNetworkHost(RelayMatrix.label($0)) }
        let dmChanges = dmEdited ? setDiff(before: p.dms, after: newDMs, job: .dms) : []
        let publishDMs = dmEdited && p.dmListKnown && !dmChanges.isEmpty

        let localChanges: [Change] = allRelays(state).compactMap { k, url in
            let before = jobs(start, k)
            let after = jobs(draft, k)
            let local: Set<Job> = yours.contains(k) ? [.search, .importing] : Set(Job.allCases)
            let added = after.subtracting(before).intersection(local)
            let removed = before.subtracting(after).intersection(local)
            return added.isEmpty && removed.isEmpty ? nil : Change(url: url, added: added, removed: removed)
        }

        return Plan(
            relayListTags: publishRelayList ? newTags : nil,
            relayListChanges: relayListChanges,
            dmRelays: publishDMs ? newDMs : nil,
            dmChanges: dmChanges,
            localChanges: localChanges,
            relayListHeld: relayListEdited && !p.relayListKnown,
            dmListHeld: dmEdited && !p.dmListKnown)
    }

    private static func movedAny(_ state: State, _ wanted: Set<Job>) -> Bool {
        state.layout.contains { state.moved.contains($0.key) && !jobs(state.draft, $0.key).isDisjoint(with: wanted) }
    }

    /// After Save: the saved lists become the start, removed rows leave, and
    /// every other row keeps its place, including defaults now published.
    enum SaveCheck: Equatable { case ok, changed, unknown }

    /// Right before a Save publishes: the lists read again (`fresh`) must be
    /// known and the same as when the page opened (`opened`), for each list
    /// the Save publishes. Otherwise the Save would put this page's copy over
    /// a list another app changed meanwhile.
    static func saveCheck(opened: Published, fresh: Published, plan: Plan) -> SaveCheck {
        func same(_ a: [String], _ b: [String]) -> Bool { Set(a.map(RelayMatrix.key)) == Set(b.map(RelayMatrix.key)) }
        if plan.relayListTags != nil {
            guard fresh.relayListKnown else { return .unknown }
            guard same(opened.read, fresh.read), same(opened.write, fresh.write), opened.kept == fresh.kept else { return .changed }
        }
        if plan.dmRelays != nil {
            guard fresh.dmListKnown else { return .unknown }
            guard same(opened.dms, fresh.dms) else { return .changed }
        }
        return .ok
    }

    static func saved(_ state: State, plan: Plan) -> State {
        var published = state.published
        if let tags = plan.relayListTags?.filter({ listable($0[1]) }) {
            published.read = tags.filter { $0.count == 2 || ($0.count > 2 && $0[2] == "read") }.map { $0[1] }
            published.write = tags.filter { $0.count == 2 || ($0.count > 2 && $0[2] == "write") }.map { $0[1] }
        }
        if let dms = plan.dmRelays { published.dms = dms }
        var next = state
        next.start = state.draft
        next.layout = state.layout.filter { state.removed[$0.key] == nil }
        next.removed = [:]
        next.published = published
        next.moved = []
        return next
    }

    /// Read/Write per relay between two kind 10002 tag lists.
    private static func diff(before: [[String]], after: [[String]]) -> [Change] {
        func jobsOf(_ tags: [[String]]) -> (order: [String], map: [String: (url: String, jobs: Set<Job>)]) {
            var order: [String] = []
            var out: [String: (url: String, jobs: Set<Job>)] = [:]
            for tag in tags where tag.count >= 2 && tag[0] == "r" {
                let marker = tag.count > 2 ? tag[2] : ""
                let jobs: Set<Job> = marker == "read" ? [.read] : marker == "write" ? [.write] : [.read, .write]
                let k = RelayMatrix.key(tag[1])
                if out[k] == nil { order.append(k) }
                out[k] = (out[k]?.url ?? tag[1], (out[k]?.jobs ?? []).union(jobs))
            }
            return (order, out)
        }
        let b = jobsOf(before)
        let a = jobsOf(after)
        var seen = Set<String>()
        return (a.order + b.order).compactMap { k in
            guard seen.insert(k).inserted else { return nil }
            let was = b.map[k]?.jobs ?? []
            let now = a.map[k]?.jobs ?? []
            guard was != now else { return nil }
            return Change(url: (a.map[k] ?? b.map[k])!.url, added: now.subtracting(was), removed: was.subtracting(now))
        }
    }

    private static func setDiff(before: [String], after: [String], job: Job) -> [Change] {
        let b = keys(before)
        let a = keys(after)
        return after.filter { !b.contains(RelayMatrix.key($0)) }.map { Change(url: $0, added: [job], removed: []) }
            + before.filter { !a.contains(RelayMatrix.key($0)) }.map { Change(url: $0, added: [], removed: [job]) }
    }
}
