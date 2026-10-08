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
    /// Draft IDs deleted while relay was offline. Applied when relay comes online.
    private var pendingDeletes: Set<String> = []

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
    }

    private func syncOnRelayReady() async {
        // 1. Flush pending deletes
        for draftId in pendingDeletes {
            await deleteFromRelay(id: draftId)
        }
        pendingDeletes.removeAll()

        // 2. Flush pending saves
        for draft in pendingSaves {
            await saveToRelay(draft: draft)
        }
        pendingSaves.removeAll()

        // 3. Fetch from relay and merge with local cache
        await fetchDrafts()
    }

    // MARK: - Save Draft

    /// Save a draft locally first (guaranteed), then sync to the /private relay.
    /// Because kind 31234 is a parameterized replaceable event, re-publishing with the
    /// same `d` tag automatically replaces the previous version in the relay store.
    func saveDraft(
        draftId: String,
        content: String,
        replyTo: FeedNote?,
        quoteTo: FeedNote?,
        taggedPubkeys: [String]
    ) async {
        // 1. Always update local state + disk first (guaranteed persistence)
        let draft = saveDraftLocally(
            draftId: draftId,
            content: content,
            replyTo: replyTo,
            quoteTo: quoteTo,
            taggedPubkeys: taggedPubkeys
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
        taggedPubkeys: [String]
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
            pubkey: NostrService.shared.activeHexPubkey,
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

        let relayReady = await RelayProcessManager.shared.ensureRelayReady(timeout: 10.0)
        guard relayReady else { return }

        let config = ConfigService.shared.config
        guard let privateURL = URL(string: config.nostrURL + "/private") else { return }

        isLoading = true
        defer { isLoading = false }

        let client = WebSocketClient()
        client.isTemporary = true

        let subId = "drafts-\(UUID().uuidString.prefix(8))"
        var receivedEvents: [NostrEvent] = []

        func sendReq() {
            let filter: [String: Any] = [
                "kinds": [31234],
                "authors": [ownPubkey]
            ]
            let req: [Any] = ["REQ", subId, filter]
            if let data = try? JSONSerialization.data(withJSONObject: req),
               let str = String(data: data, encoding: .utf8) {
                client.send(text: str)
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var hasResumed = false
            // /private requires NIP-42 AUTH before it'll answer a REQ (see
            // haven-go/init.go's khatru.RequestAuth + policies.MustAuth) — without
            // this, the REQ above is silently rejected and we just burn the full
            // 5s timeout below on every call, never actually fetching drafts.
            var authSent = false

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        sendReq()
                    }
                }
                .store(in: &self.cancellables)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { text in
                    guard let data = text.data(using: .utf8),
                          let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = arr.first as? String else { return }

                    if type == "AUTH", !authSent, let challenge = arr[safe: 1] as? String {
                        authSent = true
                        Task {
                            guard let authEvent = await NostrService.shared.signEventAsync(
                                kind: 22242, content: "",
                                tags: [["relay", config.nostrURL + "/private"], ["challenge", challenge]],
                                forceOwner: true
                            ) else { return }
                            let msg: [Any] = ["AUTH", self.eventToDict(authEvent)]
                            if let msgData = try? JSONSerialization.data(withJSONObject: msg),
                               let msgStr = String(data: msgData, encoding: .utf8) {
                                client.send(text: msgStr)
                            }
                            // The original REQ (sent immediately on connect, before this
                            // challenge arrived) was rejected pre-auth — resend now.
                            sendReq()
                        }
                        return
                    }

                    if type == "EVENT", arr.count >= 3,
                       let eventDict = arr[2] as? [String: Any],
                       let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
                       let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {
                        receivedEvents.append(event)
                    } else if type == "EOSE" {
                        client.disconnect()
                        if !hasResumed {
                            hasResumed = true
                            continuation.resume()
                        }
                    }
                }
                .store(in: &self.cancellables)

            // Timeout after 5 seconds in case EOSE never arrives
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if !hasResumed {
                    hasResumed = true
                    client.disconnect()
                    continuation.resume()
                }
            }

            client.connect(url: privateURL)
        }

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
        // Always remove from local state + disk immediately
        drafts.removeAll { $0.id == draftId }
        pendingSaves.removeAll { $0.id == draftId }
        saveToDisk()

        // Attempt relay-side deletion
        let relayReady = await RelayProcessManager.shared.ensureRelayReady(timeout: 5.0)
        if relayReady {
            await deleteFromRelay(id: draftId)
        } else {
            pendingDeletes.insert(draftId)
        }
    }

    private func deleteFromRelay(id draftId: String) async {
        let pubkey = NostrService.shared.activeHexPubkey
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
        let config = ConfigService.shared.config
        guard let url = URL(string: config.nostrURL + "/private") else { return false }

        let msg: [Any] = ["EVENT", [
            "id": event.id,
            "pubkey": event.pubkey,
            "created_at": event.created_at,
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content,
            "sig": event.sig
        ] as [String: Any]]

        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return false }

        let client = WebSocketClient()
        client.isTemporary = true

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            var hasResumed = false

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        client.send(text: str)
                    }
                }
                .store(in: &self.cancellables)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { text in
                    guard let msgData = text.data(using: .utf8),
                          let arr = try? JSONSerialization.jsonObject(with: msgData) as? [Any],
                          let type = arr.first as? String else { return }

                    if type == "OK", arr.count >= 3 {
                        let success = (arr[2] as? Bool) ?? false
                        client.disconnect()
                        if !hasResumed {
                            hasResumed = true
                            continuation.resume(returning: success)
                        }
                    }
                }
                .store(in: &self.cancellables)

            // Timeout after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if !hasResumed {
                    hasResumed = true
                    client.disconnect()
                    continuation.resume(returning: false)
                }
            }

            client.connect(url: url)
        }
    }

    private func eventToDict(_ event: NostrEvent) -> [String: Any] {
        return [
            "id": event.id,
            "pubkey": event.pubkey,
            "created_at": event.created_at,
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content,
            "sig": event.sig
        ]
    }
}
