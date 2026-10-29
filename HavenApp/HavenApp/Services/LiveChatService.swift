import Foundation
import Combine

/// Chat for one live stream (NIP-53 kind 1311), with the stream's zap receipts
/// (kind 9735) mixed into the same column — which is how every other live
/// client shows them, and the only reason a zap is worth sending in public.
///
/// One instance per open player, not a singleton: the subscription is scoped to
/// a single stream address and must die with the sheet.
@MainActor
final class LiveChatService: ObservableObject {
    @Published private(set) var messages: [LiveChatMessage] = []
    @Published private(set) var isSending = false

    /// The newest 300. A busy stream will outrun any list we keep, and the
    /// interesting end is the bottom.
    private static let maxMessages = 300

    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()
    private var collected: [String: LiveChatMessage] = [:]
    private var address: String?
    /// Muted from this chat while it was open.
    private var hidden = Set<String>()
    /// Signatures are checked here, not on main: a busy stream answers with
    /// a hundred events from each of five relays.
    private static let verifyQueue = DispatchQueue(label: "com.haven.live-chat-verify", qos: .userInitiated)

    deinit {
        clients.forEach { $0.disconnect() }
    }

    func connect(to stream: LiveStream) {
        guard address != stream.address else { return }
        disconnect()
        address = stream.address
        collected.removeAll()
        messages = []

        let relayURLs = Self.relayURLs(for: stream)
        guard !relayURLs.isEmpty else { return }

        let subId = "livechat-\(UUID().uuidString.prefix(8))"
        let filter: [String: Any] = [
            "kinds": [1311, 9735],
            "#a": [stream.address],
            "limit": 100
        ]
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true
            clients.append(client)

            // Rows are parsed and verified on `verifyQueue`, then land on the
            // main actor before they touch `collected`, which is what keeps
            // five simultaneous answers from racing on one dictionary.
            let address = stream.address
            client.messageSubject
                .receive(on: Self.verifyQueue)
                .compactMap { Self.verifiedRow(message: $0, address: address) }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] row in
                    self?.handle(row: row, address: address, blocked: blocked)
                }
                .store(in: &cancellables)

            client.connect(url: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let req = ["REQ", subId, filter] as [Any]
                if let data = try? JSONSerialization.data(withJSONObject: req),
                   let text = String(data: data, encoding: .utf8) {
                    client.send(text: text)
                }
            }
        }
    }

    func disconnect() {
        cancellables.removeAll()
        clients.forEach { $0.disconnect() }
        clients.removeAll()
        address = nil
    }

    /// Publishes a chat message to the stream's own relays.
    ///
    /// The vault's local relay gets a copy so the owner keeps what they said,
    /// but it cannot be the only destination: nobody else in the stream reads
    /// this device's relay, so a chat message that only goes there is a message
    /// nobody sees.
    func send(_ text: String, stream: LiveStream) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return false }
        isSending = true
        defer { isSending = false }

        let tags: [[String]] = [
            ["a", stream.address, LiveChat.streamRelay],
            ["client", "Nostr Vault"]
        ]
        guard let signed = await NostrService.shared.signEventAsync(kind: 1311, content: trimmed, tags: tags) else {
            return false
        }

        let eventDict: [String: Any] = [
            "id": signed.id,
            "pubkey": signed.pubkey,
            "created_at": signed.created_at,
            "kind": signed.kind,
            "tags": signed.tags,
            "content": signed.content,
            "sig": signed.sig
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: ["EVENT", eventDict] as [Any]),
              let payload = String(data: data, encoding: .utf8) else { return false }

        // Reuse the sockets this chat is already subscribed on — the relays that
        // carry the stream are exactly the ones the message belongs on.
        var reached = false
        for client in clients where client.connectionState == .connected {
            client.send(text: payload)
            reached = true
        }
        if !reached {
            for url in Self.relayURLs(for: stream) {
                let client = WebSocketClient()
                client.isTemporary = true
                client.$connectionState
                    .receive(on: DispatchQueue.main)
                    .sink { state in
                        if state == .connected {
                            client.send(text: payload)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { client.disconnect() }
                        }
                    }
                    .store(in: &cancellables)
                client.connect(url: url)
            }
        }

        _ = FeedService.shared.sendToLocalRelay(payload)

        // Show it immediately. The relay echo carries the same id, so the
        // dictionary collapses the two rather than double-printing.
        if let mine = LiveChat.message(id: signed.id, pubkey: signed.pubkey, kind: signed.kind,
                                       createdAt: signed.created_at, content: signed.content,
                                       tags: signed.tags) {
            collected[mine.id] = mine
            publish()
        }
        return true
    }

    /// Takes someone's rows out after they are muted from the chat, and
    /// keeps their later ones out: the block list was read once, at connect.
    func hide(authorPubkey: String) {
        hidden.insert(authorPubkey)
        collected = collected.filter { $0.value.authorPubkey != authorPubkey }
        messages.removeAll { $0.authorPubkey == authorPubkey }
    }

    // MARK: - Private

    /// The stream's own answer first, then the relays that actually carry live
    /// chat. Reaching for the documented relay first shows an empty room.
    private static func relayURLs(for stream: LiveStream) -> [URL] {
        LiveChat.chatRelays(streamRelays: stream.chatRelays,
                            userRelays: ConfigService.shared.config.activeFeedRelays)
            .compactMap { URL(string: $0) }
    }

    /// Runs on `verifyQueue`. A row only exists if its event is signed by the
    /// pubkey it claims: the stream chooses the first relays this chat reads,
    /// so a hostile stream could otherwise put words, and a Mute button, under
    /// anyone's name. A zap's payer needs the embedded request's signature
    /// too, on a request made for this stream.
    nonisolated private static func verifiedRow(message: String, address: String) -> LiveChatMessage? {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json.first as? String,
              type == "EVENT", json.count >= 3,
              let event = json[2] as? [String: Any],
              let id = event["id"] as? String,
              let pubkey = event["pubkey"] as? String,
              let createdAt = event["created_at"] as? Int64,
              let kind = event["kind"] as? Int,
              let tags = event["tags"] as? [[String]],
              let content = event["content"] as? String
        else { return nil }

        // A relay is free to answer a `#a` filter loosely; only rows tagged with
        // this exact stream belong in this chat.
        guard tags.contains(where: { $0.count >= 2 && $0[0] == "a" && $0[1] == address }),
              NostrEventVerifier.isValid(event)
        else { return nil }

        return LiveChat.message(id: id, pubkey: pubkey, kind: kind, createdAt: createdAt,
                                content: content, tags: tags, streamAddress: address,
                                verifyRequest: NostrEventVerifier.isValid(json:))
    }

    private func handle(row: LiveChatMessage, address: String, blocked: Set<String>) {
        // A late answer from the stream that was open before.
        guard self.address == address else { return }
        if let author = row.authorPubkey {
            guard !blocked.contains(author), !hidden.contains(author) else { return }
        }
        guard collected[row.id] == nil else { return }
        collected[row.id] = row
        publish()
    }

    private func publish() {
        var sorted = collected.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }
        if sorted.count > Self.maxMessages {
            sorted.removeFirst(sorted.count - Self.maxMessages)
            collected = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
        }
        messages = sorted
        NostrService.shared.fetchMissingProfiles(for: Array(Set(sorted.suffix(60).compactMap(\.authorPubkey))))
    }
}
