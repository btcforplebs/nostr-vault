import SwiftUI
import Combine

extension NoteDetailView {
    func fetchReplies() {
        guard !isLoadingReplies else { return }
        isLoadingReplies = true
        // A refresh replaces the live subscriptions rather than doubling them.
        replyClients.forEach { $0.disconnect() }
        replyClients.removeAll()

        // Try local relay AND external relays to find replies
        var relayURLs: [URL] = [configService.config.nostrURL].compactMap { URL(string: $0) }
        let externalStrs = configService.config.readRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        let subId = "replies-\(UUID().uuidString.prefix(8))"
        var activeClients: [WebSocketClient] = []

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true // Clean up when done
            activeClients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    self.handleReplyMessage(msg, client: client)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let targetRootId = self.threadRootId
                        let activeFocusId = self.focusedNoteId.isEmpty ? self.note.id : self.focusedNoteId
                        
                        let repliesFilter: [String: Any] = ["kinds": [1], "#e": [targetRootId], "limit": 150]
                        // NIP-22 comments name the thread root in uppercase E,
                        // so one filter reaches them at any depth.
                        let commentsFilter: [String: Any] = ["kinds": [NIP10Thread.commentKind], "#E": [targetRootId], "limit": 150]
                        let engagementFilter: [String: Any] = ["kinds": [6, 7, 9735], "#e": [activeFocusId], "limit": 150]
                        var filters: [[String: Any]] = [repliesFilter, commentsFilter, engagementFilter]
                        if let coord = self.threadRootCoordinate {
                            filters.append(["kinds": [NIP10Thread.commentKind], "#A": [coord], "limit": 150])
                        }
                        // Other responses: quotes of any kind (#q), and
                        // highlights / voice replies pointing at the root.
                        filters.append(["#q": [targetRootId], "limit": 50])
                        filters.append(["kinds": Self.otherResponseKinds, "#e": [targetRootId], "limit": 50])
                        // An article's highlights name it by address, not by
                        // this version's id, so `#e` alone never finds them.
                        if let coord = self.threadRootCoordinate {
                            filters.append(["kinds": Self.otherResponseKinds, "#a": [coord], "limit": 50])
                        }
                        let req = (["REQ", subId] as [Any]) + filters.map { $0 as Any }
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
        }
        replyClients = activeClients

        // Reveal whatever has arrived after 6 seconds even if no relay has
        // finished. The subscriptions stay open: later replies stream in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            if self.isLoadingReplies {
                self.flushPendingReplies()
            }
        }
    }

    /// Highlights (9802) and voice replies (1244) go below the fold.
    static let otherResponseKinds = [9802, 1244]

    /// A response that isn't a thread row: a quote (a `q` tag on the root,
    /// and not itself a reply), a highlight, a voice reply, or any other
    /// kind that points at the root. Replies, comments, reactions, reposts
    /// and zaps are handled where they always were.
    private func isOtherResponse(kind: Int, tags: [[String]]) -> Bool {
        if [1, NIP10Thread.commentKind, 6, 7, 9735].contains(kind) {
            guard kind == 1 else { return false }
            let quotesRoot = tags.contains { $0.count >= 2 && $0[0] == "q" && $0[1] == threadRootId }
            return quotesRoot && NIP10Thread.parentEventId(kind: kind, tags: tags) == nil
        }
        return true
    }

    private func handleReplyMessage(_ msg: String, client: WebSocketClient) {
        guard let data = msg.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EVENT", json.count >= 3,
           let ev = json[2] as? [String: Any],
           let id = ev["id"] as? String,
           let pubkey = ev["pubkey"] as? String,
           let content = ev["content"] as? String,
           let createdAt = ev["created_at"] as? Int64,
           let kind = ev["kind"] as? Int,
           let tags = ev["tags"] as? [[String]] {
            // A deleted post never comes back as a parent or a reply.
            if feedService.isDeleted(id) { return }

            if isOtherResponse(kind: kind, tags: tags) {
                // Shown as "<name> highlighted this": it must really be theirs.
                if !otherResponses.contains(where: { $0.id == id }),
                   NostrEventVerifier.isValid(ev),
                   !FeedNote.isNoiseOrSpam(content: content, tags: tags) {
                    otherResponses.append(FeedNote(
                        id: id, pubkey: pubkey, content: content,
                        createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                        tags: tags, kind: kind
                    ))
                    otherResponses.sort { $0.createdAt > $1.createdAt }
                    if nostrService.profiles[pubkey] == nil {
                        nostrService.fetchMissingProfiles(for: [pubkey])
                    }
                }
            } else if kind == 1 || kind == NIP10Thread.commentKind {
                let reply = FeedNote(
                    id: id,
                    pubkey: pubkey,
                    content: content,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                    tags: tags,
                    kind: kind
                )

                if !FeedNote.isNoiseOrSpam(content: content, tags: tags) {
                    if isLoadingReplies {
                        // Buffer while loading — all revealed at once on EOSE
                        if !pendingReplies.contains(where: { $0.id == id }) {
                            pendingReplies.append(reply)
                        }
                    } else {
                        // Already revealed — late arrivals added directly
                        if feedService.findNote(id: id) == nil {
                            feedService.addNote(reply)
                        }
                    }

                    // Pre-fetch profile so it's ready by reveal time
                    if nostrService.profiles[pubkey] == nil {
                        nostrService.fetchMissingProfiles(for: [pubkey])
                    }
                }
            } else if kind == 7 {
                if !self.detailedReactions.contains(where: { $0.id == id }) {
                    if let evData = try? JSONSerialization.data(withJSONObject: ev),
                       let event = try? JSONDecoder().decode(NostrEvent.self, from: evData) {
                        self.detailedReactions.append(event)
                        if nostrService.profiles[pubkey] == nil {
                            nostrService.fetchMissingProfiles(for: [pubkey])
                        }
                    }
                }
            } else if kind == 6 {
                if !self.detailedReposts.contains(where: { $0.id == id }) {
                    if let evData = try? JSONSerialization.data(withJSONObject: ev),
                       let event = try? JSONDecoder().decode(NostrEvent.self, from: evData) {
                        self.detailedReposts.append(event)
                        if nostrService.profiles[pubkey] == nil {
                            nostrService.fetchMissingProfiles(for: [pubkey])
                        }
                    }
                }
            } else if kind == 9735 {
                if !self.detailedZaps.contains(where: { $0.id == id }) {
                    if let evData = try? JSONSerialization.data(withJSONObject: ev),
                       let event = try? JSONDecoder().decode(NostrEvent.self, from: evData) {
                        self.detailedZaps.append(event)
                        if let descJson = event.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
                           let descData = descJson.data(using: .utf8),
                           let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
                           let senderPubkey = zapReq["pubkey"] as? String {
                            if nostrService.profiles[senderPubkey] == nil {
                                nostrService.fetchMissingProfiles(for: [senderPubkey])
                            }
                        }
                    }
                }
            }
        } else if type == "EOSE" {
            // Stored replies are all in; stay subscribed for new ones.
            if isLoadingReplies {
                flushPendingReplies()
            }
        }
    }

    private func flushPendingReplies() {
        // Add all buffered replies to feedService at once
        for reply in pendingReplies {
            if feedService.findNote(id: reply.id) == nil {
                feedService.addNote(reply)
            }
        }
        pendingReplies.removeAll()

        withAnimation(Motion.fade) {
            isLoadingReplies = false
        }
    }

    /// Fetch replies specifically for a given note ID (used when focus changes within the thread).
    /// The initial fetchReplies() queries by thread root; this catches any replies that only
    /// reference this specific note and not the root (e.g. legacy clients).
    func fetchRepliesForNote(_ noteId: String) {
        var relayURLs: [URL] = [configService.config.nostrURL].compactMap { URL(string: $0) }
        let externalStrs = configService.config.readRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        let subId = "focus-replies-\(UUID().uuidString.prefix(8))"

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    guard let data = msg.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = json[0] as? String else { return }

                    if type == "EVENT", json.count >= 3,
                       let ev = json[2] as? [String: Any],
                       let id = ev["id"] as? String,
                       let pubkey = ev["pubkey"] as? String,
                       let content = ev["content"] as? String,
                       let createdAt = ev["created_at"] as? Int64,
                       let kind = ev["kind"] as? Int,
                       let tags = ev["tags"] as? [[String]],
                       kind == 1 || kind == NIP10Thread.commentKind {

                        let reply = FeedNote(
                            id: id,
                            pubkey: pubkey,
                            content: content,
                            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                            tags: tags,
                            kind: kind
                        )

                        if !FeedNote.isNoiseOrSpam(content: content, tags: tags),
                           self.feedService.findNote(id: id) == nil {
                            self.feedService.addNote(reply)
                        }

                        if self.nostrService.profiles[pubkey] == nil {
                            self.nostrService.fetchMissingProfiles(for: [pubkey])
                        }
                    } else if type == "EOSE" {
                        client.disconnect()
                    }
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let filter: [String: Any] = ["kinds": [1, NIP10Thread.commentKind], "#e": [noteId], "limit": 150]
                        let req = ["REQ", subId, filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)

            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                client.disconnect()
            }
        }
    }

    func fetchEngagement(for eventId: String) {
        // Clear previous reactions to prevent flash of wrong data
        detailedReactions.removeAll()
        detailedReposts.removeAll()
        detailedZaps.removeAll()

        var relayURLs: [URL] = [configService.config.nostrURL].compactMap { URL(string: $0) }
        let externalStrs = configService.config.readRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        let subId = "eng-\(eventId.prefix(6))-\(UUID().uuidString.prefix(4))"
        
        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { msg in
                    self.handleReplyMessage(msg, client: client)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let filter: [String: Any] = ["kinds": [6, 7, 9735], "#e": [eventId], "limit": 100]
                        let req = ["REQ", subId, filter] as [Any]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                client.disconnect()
            }
        }
    }
}
