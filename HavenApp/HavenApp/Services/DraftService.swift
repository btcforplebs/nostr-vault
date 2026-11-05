import Foundation
import Combine

// MARK: - Draft Model

struct Draft: Identifiable, Equatable, Codable {
    let id: String              // the "d" tag value (UUID string)
    var content: String
    var pubkey: String?         // author pubkey (nil for legacy drafts)
    var replyToId: String?      // event ID of parent note (NIP-10 "reply" marker)
    var rootId: String?         // thread root event ID (NIP-10 "root" marker)
    var quoteId: String?        // quoted event ID (q-tag)
    var quotePubkey: String?    // quoted author pubkey
    var tags: [[String]]        // full NIP-10 tags preserved for restore
    var updatedAt: Date

    var preview: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 80 { return trimmed }
        return String(trimmed.prefix(80)) + "..."
    }

    var isReply: Bool { replyToId != nil }
    var isQuote: Bool { quoteId != nil }
}

// MARK: - DraftService

@MainActor
class DraftService: ObservableObject {
    static let shared = DraftService()

    @Published var drafts: [Draft] = []
    @Published var isLoading: Bool = false

    /// Drafts filtered to the currently active account.
    var draftsForActiveAccount: [Draft] {
        let activePubkey = NostrService.shared.activeHexPubkey
        guard !activePubkey.isEmpty else { return drafts }
        return drafts.filter { $0.pubkey == nil || $0.pubkey == activePubkey }
    }

    /// Pending saves that failed relay sync. Drained when relay comes online.
    private var pendingSaves: [Draft] = []
    /// Drafts deleted while relay was offline, with the account each was
    /// deleted as. Applied when relay comes online and that account is active.
    private var pendingDeletes: Set<PendingDraftDelete> = []

    private var cancellables = Set<AnyCancellable>()

    private init() {
        loadFromDisk()
        observeRelayState()
    }

    // MARK: - Local Disk Cache

    private static var cacheURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        return havenDir.appendingPathComponent("drafts.json")
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let loaded = try? JSONDecoder().decode([Draft].self, from: data) else { return }
        self.drafts = loaded.sorted { $0.updatedAt > $1.updatedAt }
        #if DEBUG
        print("DraftService: Loaded \(drafts.count) drafts from disk cache")
        #endif
    }

    /// Persists the in-memory drafts to disk. Pass `synchronous: true` to block until the
    /// write completes — used right before posting so an in-flight note survives a crash.
    private func saveToDisk(synchronous: Bool = false) {
        let snapshot = drafts
        let url = Self.cacheURL
        let write: @Sendable () -> Void = {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
        if synchronous {
            write()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: write)
        }
    }

    // MARK: - Relay State Observation

    private func observeRelayState() {
        RelayProcessManager.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                if state == .running {
                    Task { await self.syncOnRelayReady() }
                }
            }
            .store(in: &cancellables)

        // Queued items for an account go out once it is active again.
        ConfigService.shared.$config
            .map(\.activeAccountNpub)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, RelayProcessManager.shared.state == .running,
                      !self.pendingSaves.isEmpty || !self.pendingDeletes.isEmpty else { return }
                Task { await self.flushPending() }
            }
            .store(in: &cancellables)
    }

    private func syncOnRelayReady() async {
        await flushPending()
        // 3. Fetch from relay and merge with local cache
        await fetchDrafts()
    }

    /// Sends the queued deletes, then saves, that belong to the active
    /// account; the rest stay queued for theirs (DraftSyncPlan).
    private func flushPending() async {
        let active = NostrService.shared.activeHexPubkey
        let deletes = DraftSyncPlan.split(Array(pendingDeletes), author: \.pubkey, active: active)
        pendingDeletes = Set(deletes.later)
        for item in deletes.now {
            await deleteFromRelay(id: item.id, as: item.pubkey)
        }
        let saves = DraftSyncPlan.split(pendingSaves, author: \.pubkey, active: active)
        pendingSaves = saves.later
        for draft in saves.now {
            await saveToRelay(draft: draft)
        }
    }


    // MARK: - Save Draft

    /// Save a draft locally first (guaranteed), then sync to the /private relay.
    /// Because kind 31234 is a parameterized replaceable event, re-publishing with the
    /// same `d` tag automatically replaces the previous version in the relay store.
    /// `authorPubkey`: the account the composer writes as (hex); nil is the
    /// active account. A switch while typing must not move the draft.
    func saveDraft(
        draftId: String,
        content: String,
        replyTo: FeedNote?,
        quoteTo: FeedNote?,
        taggedPubkeys: [String],
        authorPubkey: String? = nil
    ) async {
        // 1. Always update local state + disk first (guaranteed persistence)
        let draft = saveDraftLocally(
            draftId: draftId,
            content: content,
            replyTo: replyTo,
            quoteTo: quoteTo,
            taggedPubkeys: taggedPubkeys,
            authorPubkey: authorPubkey
        )

        // 2. Attempt relay sync
        let relayReady = await RelayProcessManager.shared.ensureRelayReady(timeout: 5.0)
        if relayReady {
            await saveToRelay(draft: draft)
        } else {
            pendingSaves.removeAll { $0.id == draftId }
            pendingSaves.append(draft)
        }
    }

    /// Synchronously builds the draft, updates in-memory state, and writes it to disk
    /// (blocking until the write completes). Returns the persisted `Draft`. Use this when
    /// the draft MUST be durable before the next step — e.g. right before posting, so a
    /// crash during mining/broadcast can't lose the user's text. No relay sync.
    @discardableResult
    func saveDraftLocally(
        draftId: String,
        content: String,
        replyTo: FeedNote?,
        quoteTo: FeedNote?,
        taggedPubkeys: [String],
        authorPubkey: String? = nil
    ) -> Draft {
        // Build tags — mirror the NIP-10 tag logic from ComposeView.postNote()
        var tags: [[String]] = [
            ["d", draftId],
            ["k", "1"]
        ]

        if let parent = replyTo {
            let relayHint = ConfigService.shared.config.nostrURL
            let parentETags = parent.tags.filter { $0.count >= 2 && $0[0] == "e" }
            let rootTag = parentETags.first(where: { $0.count >= 4 && $0[3] == "root" })

            if let root = rootTag {
                // Replying within a thread — keep the root, mark parent as reply
                tags.append(root)
                tags.append(["e", parent.id, relayHint, "reply"])
            } else {
                // Replying to a root note
                tags.append(["e", parent.id, relayHint, "root"])
                tags.append(["e", parent.id, relayHint, "reply"])
            }

            tags.append(["p", parent.pubkey])

            // Carry forward thread participant p-tags
            for tag in parent.tags where tag.count >= 2 && tag[0] == "p" {
                let pk = tag[1]
                if !tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == pk }) {
                    tags.append(["p", pk])
                }
            }
        }

        if let quoted = quoteTo {
            tags.append(["q", quoted.id, ConfigService.shared.config.publicRelayHint, quoted.pubkey])
        }

        for pk in taggedPubkeys {
            if !tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == pk }) {
                tags.append(["p", pk])
            }
        }

        // Build Draft struct
        let draft = Draft(
            id: draftId,
            content: content,
            pubkey: (authorPubkey?.isEmpty == false ? authorPubkey : nil) ?? NostrService.shared.activeHexPubkey,
            replyToId: replyTo?.id,
            rootId: replyTo?.tags.first(where: { $0.count >= 4 && $0[0] == "e" && $0[3] == "root" })?[1],
            quoteId: quoteTo?.id,
            quotePubkey: quoteTo?.pubkey,
            tags: tags,
            updatedAt: Date()
        )

        // Update local state + disk synchronously (guaranteed persistence)
        if let idx = drafts.firstIndex(where: { $0.id == draftId }) {
            drafts[idx] = draft
        } else {
            drafts.insert(draft, at: 0)
        }
        saveToDisk(synchronous: true)

        return draft
    }

    /// Sign and send a draft event to the relay.
    private func saveToRelay(draft: Draft) async {
        // Signed with the active key: another account's draft waits for its
        // own (it used to be stored signed by whoever was active).
        guard DraftSyncPlan.isDue(author: draft.pubkey, active: NostrService.shared.activeHexPubkey) else {
            pendingSaves.removeAll { $0.id == draft.id }
            pendingSaves.append(draft)
            return
        }
        guard let event = await NostrService.shared.signEventAsync(
            kind: 31234, content: draft.content, tags: draft.tags
        ) else { return }
        await postEventToPrivateRelayConfirmed(event)
    }

    // MARK: - Fetch Drafts

    /// Query the /private relay for existing kind 31234 drafts authored by the active account,
    /// then merge with local cache (keeping the newer version of each draft).
    func fetchDrafts() async {
        let ownPubkey = NostrService.shared.activeHexPubkey
        guard !ownPubkey.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        // /private needs NIP-42 AUTH before it answers; VaultSocket waits for
        // the AUTH's OK before sending the REQ (a REQ sent right behind the
        // AUTH is refused and drafts came back empty).
        let filter: [String: Any] = ["kinds": [31234], "authors": [ownPubkey]]
        let receivedEvents = await VaultSocket.query(path: "/private", filter: filter, timeout: 5) ?? []

        // Parse relay events into Draft structs
        let relayDrafts = receivedEvents.compactMap { event -> Draft? in
            guard let dTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] else {
                return nil
            }

            let eTags = event.tags.filter { $0.count >= 2 && $0[0] == "e" }
            let replyTag = eTags.first(where: { $0.count >= 4 && $0[3] == "reply" })
            let rootTag = eTags.first(where: { $0.count >= 4 && $0[3] == "root" })
            let qTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "q" })

            return Draft(
                id: dTag,
                content: event.content,
                pubkey: event.pubkey,
                replyToId: replyTag?[1],
                rootId: rootTag?[1],
                quoteId: qTag?[1],
                quotePubkey: qTag != nil && qTag!.count >= 4 ? qTag![3] : nil,
                tags: event.tags,
                updatedAt: event.createdAtDate
            )
        }

        // Merge: keep the newer version of each draft
        var merged: [String: Draft] = [:]
        for draft in drafts { merged[draft.id] = draft }
        for draft in relayDrafts {
            if let existing = merged[draft.id] {
                merged[draft.id] = draft.updatedAt >= existing.updatedAt ? draft : existing
            } else {
                merged[draft.id] = draft
            }
        }

        drafts = Array(merged.values).sorted { $0.updatedAt > $1.updatedAt }
        saveToDisk()
    }

    // MARK: - Delete Draft

    /// Remove a draft locally and send a kind 5 deletion event to the relay.
    func deleteDraft(id draftId: String) async {
        // The account it was deleted as: its own draft, whoever is active later.
        let author = drafts.first(where: { $0.id == draftId })?.pubkey ?? NostrService.shared.activeHexPubkey
        // Always remove from local state + disk immediately
        drafts.removeAll { $0.id == draftId }
        pendingSaves.removeAll { $0.id == draftId }
        saveToDisk()

        // Attempt relay-side deletion
        let relayReady = await RelayProcessManager.shared.ensureRelayReady(timeout: 5.0)
        if relayReady {
            await deleteFromRelay(id: draftId, as: author)
        } else {
            pendingDeletes.insert(PendingDraftDelete(id: draftId, pubkey: author))
        }
    }

    /// The kind 5 names `author`'s draft and is signed by the active key, so
    /// it waits until that account is active (DraftSyncPlan).
    private func deleteFromRelay(id draftId: String, as author: String?) async {
        let active = NostrService.shared.activeHexPubkey
        guard DraftSyncPlan.isDue(author: author, active: active) else {
            pendingDeletes.insert(PendingDraftDelete(id: draftId, pubkey: author))
            return
        }
        let pubkey = (author?.isEmpty == false ? author! : active)
        let aTag = "31234:\(pubkey):\(draftId)"
        if let event = await NostrService.shared.signEventAsync(
            kind: 5, content: "", tags: [["a", aTag]]
        ) {
            await postEventToPrivateRelayConfirmed(event)
        }
    }

    // MARK: - Private Relay Communication

    /// Post an event to the /private relay endpoint and wait for the Nostr OK response.
    @discardableResult
    private func postEventToPrivateRelayConfirmed(_ event: NostrEvent) async -> Bool {
        await VaultSocket.publish(event, path: "/private", timeout: 5)
    }
}

// MARK: - Reply parent (drafts list + resume)

extension Draft {
    /// The parent's author, from the saved tags (`DraftReplyParent`).
    var parentPubkey: String? { DraftReplyParent.parentPubkey(replyToId: replyToId, tags: tags) }

    /// A parent built from this draft's saved tags, so a resumed reply opens
    /// as "Reply" and posts with the same root/reply tags even before the real
    /// note loads, or when no relay has it.
    var standInParent: FeedNote? {
        guard let id = replyToId, let pubkey = parentPubkey else { return nil }
        return FeedNote(id: id, pubkey: pubkey, content: "", createdAt: updatedAt,
                        tags: DraftReplyParent.standInTags(replyToId: id, rootId: rootId, parentPubkey: pubkey, tags: tags),
                        kind: 1)
    }
}

/// Loads the note a reply draft answers: from memory, else from this device's
/// relay and the read relays, then keeps it in the feed's parent cache.
@MainActor
enum DraftParentLoader {
    static func load(_ id: String) async -> FeedNote? {
        let feed = FeedService.shared
        if let note = feed.findNote(id: id) { return note }
        let config = ConfigService.shared.config
        let relays = [config.nostrURL, config.nostrURL + "/inbox"] + config.readRelays
        let events = await NostrService.shared.fetchEvents(filter: ["ids": [id], "limit": 1], from: relays,
                                                           timeout: 6, includeLoopback: true)
        guard let ev = events.first(where: { $0.id == id }) else { return nil }
        let note = FeedNote(id: ev.id, pubkey: ev.pubkey, content: ev.content, createdAt: ev.createdAtDate,
                            tags: ev.tags, kind: ev.kind)
        feed.parentNotesCache[id] = note
        return note
    }
}
