import Foundation
import Combine

// MARK: - GroupService

@MainActor
class GroupService: ObservableObject {
    static let shared = GroupService()

    @Published var conversations: [GroupConversation] = []
    @Published var isLoading: Bool = false
    @Published var availableGroups: [GroupInfo] = []

    /// Lifecycle of a relay browse. The browser needs to tell "still asking"
    /// apart from "the relay answered with no groups" and "the relay never
    /// answered" — an empty list means all three otherwise.
    enum BrowseState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published var browseState: BrowseState = .idle

    var totalUnreadCount: Int {
        conversations.reduce(0) { $0 + $1.unreadCount }
    }

    private var relayClients: [String: WebSocketClient] = [:]
    private var cancellables = Set<AnyCancellable>()
    /// Per-relay Combine subscriptions, keyed by relay URL.
    /// Cancelled individually on reconnect to avoid tearing down all relays.
    private var relayCancellables: [String: Set<AnyCancellable>] = [:]
    private var seenEventIds = Set<String>()
    private var groupUpdateSubject = PassthroughSubject<Void, Never>()
    private let processingQueue = DispatchQueue(label: "com.haven.group-processing", qos: .userInitiated)
    private var authenticatedRelays = Set<String>()
    /// Relay the in-flight browse is addressed to, and a generation counter so a
    /// late EOSE or timeout from a superseded browse cannot resolve the current one.
    private var browsingRelay: String?
    private var browseGeneration: UInt64 = 0
    /// Generous enough to cover the 2s connect wait plus a slow relay's round trip.
    private let browseTimeout: TimeInterval = 12
    private var loadedAccountPubkey: String = ""
    private var switchGeneration: UInt64 = 0

    private init() {
        loadedAccountPubkey = NostrService.shared.activeHexPubkey
        setupThrottling()
        loadConversations()

        ConfigService.shared.$config
            .map { $0.activeAccountNpub }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleAccountSwitch()
            }
            .store(in: &cancellables)
    }

    // MARK: - Connection Management

    func connectToGroupRelays() {
        let relayURLs = ConfigService.shared.config.groupRelayURLs
        for urlStr in relayURLs {
            connectToRelay(urlStr)
        }
    }

    func connectToRelay(_ urlStr: String) {
        guard let url = URL(string: urlStr) else { return }

        // Tear down existing connection for this relay
        relayCancellables[urlStr]?.forEach { $0.cancel() }
        relayCancellables[urlStr] = nil
        relayClients[urlStr]?.disconnect()
        authenticatedRelays.remove(urlStr)

        let client = WebSocketClient()
        relayClients[urlStr] = client
        var subs = Set<AnyCancellable>()

        client.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] message in
                self?.processMessage(message, fromRelay: urlStr)
            }
            .store(in: &subs)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self, self.relayClients[urlStr] === client else { return }
                switch state {
                case .connected:
                    #if DEBUG
                    print("GroupService: Connected to \(urlStr), awaiting AUTH...")
                    #endif
                    // Some relays don't require AUTH — subscribe immediately as fallback
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self = self else { return }
                        if !self.authenticatedRelays.contains(urlStr) {
                            self.authenticatedRelays.insert(urlStr)
                            self.subscribeToJoinedGroups(on: urlStr)
                        }
                    }
                case .error:
                    self.authenticatedRelays.remove(urlStr)
                    // Only a socket-level error fails a browse. `.disconnected`
                    // also fires on ordinary teardown, including our own.
                    if urlStr == self.browsingRelay, self.browseState == .loading {
                        self.browseState = .failed(String(localized: "group.browser.error.unreachable"))
                    }
                case .disconnected:
                    self.authenticatedRelays.remove(urlStr)
                default:
                    break
                }
            }
            .store(in: &subs)

        relayCancellables[urlStr] = subs
        client.connect(url: url)
    }

    func disconnectAll() {
        for (_, client) in relayClients {
            client.disconnect()
        }
        relayClients.removeAll()
        relayCancellables.removeAll()
        authenticatedRelays.removeAll()
    }

    // MARK: - NIP-42 AUTH

    private func handleAuthChallenge(_ challenge: String, relayURL: String) {
        guard let client = relayClients[relayURL] else { return }

        let tags: [[String]] = [
            ["relay", relayURL],
            ["challenge", challenge]
        ]

        Task {
            guard let authEvent = await NostrService.shared.signEventAsync(
                kind: 22242, content: "", tags: tags
            ) else {
                #if DEBUG
                print("GroupService: Failed to sign AUTH event for \(relayURL)")
                #endif
                return
            }

            let eventDict = eventToDict(authEvent)
            let msg = ["AUTH", eventDict] as [Any]
            if let data = try? JSONSerialization.data(withJSONObject: msg),
               let str = String(data: data, encoding: .utf8) {
                client.send(text: str)
            }
        }
    }

    // MARK: - Subscriptions

    private func subscribeToJoinedGroups(on relayURL: String) {
        guard let client = relayClients[relayURL] else { return }

        let joinedOnRelay = ConfigService.shared.config.joinedGroups
            .filter { $0.relayURL == relayURL }

        for group in joinedOnRelay {
            let contentFilter: [String: Any] = [
                "#h": [group.groupId],
                "limit": 200
            ]
            let contentSub = "grp-content-\(group.groupId.prefix(8))"
            sendREQ(contentSub, filter: contentFilter, to: client)
        }

        // Metadata subscription for all groups on this relay
        let groupIds = joinedOnRelay.map { $0.groupId }
        if !groupIds.isEmpty {
            let metaFilter: [String: Any] = [
                "kinds": [39000, 39001, 39002, 39003],
                "#d": groupIds
            ]
            let metaSub = "grp-meta-\(urlSuffix(relayURL))"
            sendREQ(metaSub, filter: metaFilter, to: client)
        }
    }

    func browseGroups(on relayURL: String) {
        browsingRelay = relayURL
        browseGeneration &+= 1
        let generation = browseGeneration
        browseState = .loading

        if relayClients[relayURL] == nil {
            connectToRelay(relayURL)
        }

        // Save relay URL if not already saved
        if !ConfigService.shared.config.groupRelayURLs.contains(relayURL) {
            ConfigService.shared.config.groupRelayURLs.append(relayURL)
            ConfigService.shared.save()
        }

        // Wait for connection, then send browse request
        let attemptBrowse = { [weak self] in
            guard let self = self, let client = self.relayClients[relayURL] else { return }
            let filter: [String: Any] = [
                "kinds": [39000],
                "limit": 100
            ]
            self.sendREQ("grp-browse", filter: filter, to: client)
        }

        if relayClients[relayURL]?.connectionState == .connected {
            attemptBrowse()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                attemptBrowse()
            }
        }

        // A relay that accepts the socket and never answers the REQ would leave
        // the browser spinning forever, so fail the browse rather than hang.
        DispatchQueue.main.asyncAfter(deadline: .now() + browseTimeout) { [weak self] in
            guard let self = self,
                  self.browseGeneration == generation,
                  self.browseState == .loading else { return }
            self.browseState = .failed(String(localized: "group.browser.error.noResponse"))
        }
    }

    // MARK: - Message Processing

    private func processMessage(_ message: String, fromRelay relayURL: String) {
        guard let data = message.data(using: .utf8) else { return }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [Any],
                  json.count >= 2,
                  let type = json[0] as? String else { return }

            switch type {
            case "AUTH":
                if let challenge = json[safe: 1] as? String {
                    DispatchQueue.main.async {
                        self.handleAuthChallenge(challenge, relayURL: relayURL)
                    }
                }
            case "OK":
                if let _ = json[safe: 1] as? String,
                   let success = json[safe: 2] as? Bool, success {
                    DispatchQueue.main.async {
                        if !self.authenticatedRelays.contains(relayURL) {
                            self.authenticatedRelays.insert(relayURL)
                            self.subscribeToJoinedGroups(on: relayURL)
                        }
                    }
                }
            case "EVENT":
                if let eventData = json[safe: 2] as? [String: Any],
                   let eventJSON = try? JSONSerialization.data(withJSONObject: eventData),
                   let event = try? JSONDecoder().decode(NostrEvent.self, from: eventJSON) {
                    DispatchQueue.main.async {
                        self.handleIncomingEvent(event, fromRelay: relayURL)
                    }
                }
            case "EOSE":
                let subId = json[safe: 1] as? String
                DispatchQueue.main.async {
                    self.isLoading = false
                    if subId == "grp-browse",
                       relayURL == self.browsingRelay,
                       self.browseState == .loading {
                        self.browseState = .loaded
                    }
                }
            default:
                break
            }
        } catch {
            #if DEBUG
            print("GroupService: Failed to process message: \(error)")
            #endif
        }
    }

    private func handleIncomingEvent(_ event: NostrEvent, fromRelay relayURL: String) {
        guard !seenEventIds.contains(event.id) else { return }
        seenEventIds.insert(event.id)

        switch event.kind {
        case 39000:
            handleGroupMetadata(event, fromRelay: relayURL)
        case 39001:
            handleAdminList(event, fromRelay: relayURL)
        case 39002:
            handleMemberList(event, fromRelay: relayURL)
        case 39003:
            break // Roles definition — stored for future admin UI use
        case 9, 11, 12:
            handleGroupContent(event, fromRelay: relayURL)
        default:
            // Any other kind with an h-tag is group content per NIP-29
            if event.tags.contains(where: { $0.count >= 2 && $0[0] == "h" }) {
                handleGroupContent(event, fromRelay: relayURL)
            }
        }
    }

    // MARK: - Content Handling

    private func handleGroupContent(_ event: NostrEvent, fromRelay relayURL: String) {
        let generation = switchGeneration
        guard self.switchGeneration == generation else { return }

        guard let groupId = event.tags.first(where: { $0.count >= 2 && $0[0] == "h" })?[1] else { return }

        let ownPubkey = loadedAccountPubkey
        let isFromMe = event.pubkey == ownPubkey

        let message = GroupMessage(
            id: event.id,
            groupId: groupId,
            senderPubkey: event.pubkey,
            content: event.content,
            timestamp: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
            kind: event.kind,
            tags: event.tags,
            isFromMe: isFromMe
        )

        let identifier = GroupIdentifier(relayURL: relayURL, groupId: groupId)

        if let idx = conversations.firstIndex(where: { $0.identifier == identifier }) {
            guard !conversations[idx].messages.contains(where: { $0.id == event.id }) else { return }

            // Replace optimistic placeholder if this is our own message returning
            if isFromMe {
                let recentThreshold = Date().addingTimeInterval(-30)
                if let msgIdx = conversations[idx].messages.lastIndex(where: {
                    $0.isFromMe && $0.content == event.content && $0.timestamp > recentThreshold
                }) {
                    conversations[idx].messages[msgIdx] = message
                    saveConversations()
                    return
                }
            }

            conversations[idx].messages.append(message)
            conversations[idx].messages.sort { $0.timestamp < $1.timestamp }
            if !isFromMe {
                conversations[idx].unreadCount += 1
            }
        } else {
            // Auto-create conversation for joined groups
            let conversation = GroupConversation(
                identifier: identifier,
                info: nil,
                messages: [message],
                unreadCount: isFromMe ? 0 : 1,
                members: [],
                admins: []
            )
            conversations.append(conversation)
        }

        sortConversations()
        groupUpdateSubject.send()
        saveConversations()
    }

    // MARK: - Metadata Handling

    private func handleGroupMetadata(_ event: NostrEvent, fromRelay relayURL: String) {
        guard let groupId = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] else { return }

        let identifier = GroupIdentifier(relayURL: relayURL, groupId: groupId)
        let info = GroupInfo(
            identifier: identifier,
            name: event.tags.first(where: { $0.count >= 2 && $0[0] == "name" })?[1] ?? groupId,
            picture: event.tags.first(where: { $0.count >= 2 && $0[0] == "picture" })?[1] ?? "",
            about: event.tags.first(where: { $0.count >= 2 && $0[0] == "about" })?[1] ?? "",
            isPrivate: event.tags.contains(where: { $0.first == "private" }),
            isClosed: event.tags.contains(where: { $0.first == "closed" }),
            memberCount: nil
        )

        // Update browse list
        if let idx = availableGroups.firstIndex(where: { $0.id == info.id }) {
            availableGroups[idx] = info
        } else {
            availableGroups.append(info)
        }

        // Update conversation metadata if joined
        if let idx = conversations.firstIndex(where: { $0.identifier == identifier }) {
            conversations[idx].info = info
        }
    }

    private func handleAdminList(_ event: NostrEvent, fromRelay relayURL: String) {
        guard let groupId = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] else { return }
        let identifier = GroupIdentifier(relayURL: relayURL, groupId: groupId)

        let admins: [GroupMember] = event.tags
            .filter { $0.count >= 2 && $0[0] == "p" }
            .map { tag in
                let roles = tag.count >= 4 ? [tag[3]] : ["admin"]
                return GroupMember(pubkey: tag[1], roles: roles)
            }

        if let idx = conversations.firstIndex(where: { $0.identifier == identifier }) {
            conversations[idx].admins = admins
        }
    }

    private func handleMemberList(_ event: NostrEvent, fromRelay relayURL: String) {
        guard let groupId = event.tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1] else { return }
        let identifier = GroupIdentifier(relayURL: relayURL, groupId: groupId)

        let members: [GroupMember] = event.tags
            .filter { $0.count >= 2 && $0[0] == "p" }
            .map { GroupMember(pubkey: $0[1], roles: []) }

        if let idx = conversations.firstIndex(where: { $0.identifier == identifier }) {
            conversations[idx].members = members
        }
    }

    // MARK: - User Actions

    func sendMessage(content: String, toGroup identifier: GroupIdentifier, kind: Int = 9, replyTo: String? = nil) async throws {
        let ownPubkey = loadedAccountPubkey
        guard !ownPubkey.isEmpty else {
            throw GroupError.noActiveAccount
        }

        var tags: [[String]] = [["h", identifier.groupId]]
        if let parentId = replyTo {
            tags.append(["e", parentId, identifier.relayURL, "reply"])
        }

        // Optimistic UI update
        let optimisticId = UUID().uuidString
        let message = GroupMessage(
            id: optimisticId,
            groupId: identifier.groupId,
            senderPubkey: ownPubkey,
            content: content,
            timestamp: Date(),
            kind: kind,
            tags: tags,
            isFromMe: true
        )

        if let idx = conversations.firstIndex(where: { $0.identifier == identifier }) {
            conversations[idx].messages.append(message)
        }
        sortConversations()
        saveConversations()

        guard let event = await NostrService.shared.signEventAsync(
            kind: kind, content: content, tags: tags
        ) else {
            throw GroupError.signingFailed
        }

        publishToRelay(event, relayURL: identifier.relayURL)
    }

    func joinGroup(_ identifier: GroupIdentifier, inviteCode: String? = nil) async throws {
        var tags: [[String]] = [["h", identifier.groupId]]
        if let code = inviteCode {
            tags.append(["code", code])
        }

        guard let event = await NostrService.shared.signEventAsync(
            kind: 9021, content: "", tags: tags
        ) else {
            throw GroupError.signingFailed
        }

        publishToRelay(event, relayURL: identifier.relayURL)

        // Persist to config
        let joined = JoinedGroup(
            relayURL: identifier.relayURL,
            groupId: identifier.groupId,
            displayName: availableGroups.first(where: { $0.identifier == identifier })?.name ?? identifier.groupId
        )
        if !ConfigService.shared.config.joinedGroups.contains(where: { $0.relayURL == joined.relayURL && $0.groupId == joined.groupId }) {
            ConfigService.shared.config.joinedGroups.append(joined)
            ConfigService.shared.save()
        }

        // Create conversation entry and subscribe
        if !conversations.contains(where: { $0.identifier == identifier }) {
            let conversation = GroupConversation(
                identifier: identifier,
                info: availableGroups.first(where: { $0.identifier == identifier }),
                messages: [],
                unreadCount: 0,
                members: [],
                admins: []
            )
            conversations.append(conversation)
            saveConversations()
        }

        subscribeToJoinedGroups(on: identifier.relayURL)
    }

    func leaveGroup(_ identifier: GroupIdentifier) async throws {
        let tags: [[String]] = [["h", identifier.groupId]]

        guard let event = await NostrService.shared.signEventAsync(
            kind: 9022, content: "", tags: tags
        ) else {
            throw GroupError.signingFailed
        }

        publishToRelay(event, relayURL: identifier.relayURL)

        ConfigService.shared.config.joinedGroups.removeAll {
            $0.relayURL == identifier.relayURL && $0.groupId == identifier.groupId
        }
        ConfigService.shared.save()

        conversations.removeAll { $0.identifier == identifier }
        saveConversations()
    }

    // MARK: - Admin Actions

    func createGroup(on relayURL: String, name: String, about: String, isPrivate: Bool, isClosed: Bool) async throws {
        var tags: [[String]] = [
            ["name", name],
            ["about", about]
        ]
        if isPrivate { tags.append(["private"]) }
        if isClosed { tags.append(["closed"]) }

        guard let event = await NostrService.shared.signEventAsync(
            kind: 9007, content: "", tags: tags
        ) else {
            throw GroupError.signingFailed
        }

        publishToRelay(event, relayURL: relayURL)
    }

    func editGroupMetadata(_ identifier: GroupIdentifier, name: String?, about: String?, picture: String?) async throws {
        var tags: [[String]] = [["h", identifier.groupId]]
        if let n = name { tags.append(["name", n]) }
        if let a = about { tags.append(["about", a]) }
        if let p = picture { tags.append(["picture", p]) }

        guard let event = await NostrService.shared.signEventAsync(
            kind: 9002, content: "", tags: tags
        ) else {
            throw GroupError.signingFailed
        }

        publishToRelay(event, relayURL: identifier.relayURL)
    }

    func addUser(_ pubkey: String, toGroup identifier: GroupIdentifier, roles: [String] = []) async throws {
        var tags: [[String]] = [["h", identifier.groupId], ["p", pubkey]]
        for role in roles { tags.append(["role", role]) }

        guard let event = await NostrService.shared.signEventAsync(
            kind: 9000, content: "", tags: tags
        ) else {
            throw GroupError.signingFailed
        }

        publishToRelay(event, relayURL: identifier.relayURL)
    }

    func removeUser(_ pubkey: String, fromGroup identifier: GroupIdentifier) async throws {
        let tags: [[String]] = [["h", identifier.groupId], ["p", pubkey]]

        guard let event = await NostrService.shared.signEventAsync(
            kind: 9001, content: "", tags: tags
        ) else {
            throw GroupError.signingFailed
        }

        publishToRelay(event, relayURL: identifier.relayURL)
    }

    func deleteEvent(_ eventId: String, fromGroup identifier: GroupIdentifier) async throws {
        let tags: [[String]] = [["h", identifier.groupId], ["e", eventId]]

        guard let event = await NostrService.shared.signEventAsync(
            kind: 9005, content: "", tags: tags
        ) else {
            throw GroupError.signingFailed
        }

        publishToRelay(event, relayURL: identifier.relayURL)

        // Optimistic removal from local state
        if let convIdx = conversations.firstIndex(where: { $0.identifier == identifier }) {
            conversations[convIdx].messages.removeAll { $0.id == eventId }
            saveConversations()
        }
    }

    /// NIP-29 kind:9008 — asks the relay to delete the group itself.
    ///
    /// This used to live in `GroupInfoView`, where it signed the event,
    /// serialised it, dropped it on the floor and fell through to
    /// `leaveGroup`. The button said Delete Group and only ever left it, so
    /// the group stayed up for everyone else.
    func deleteGroup(_ identifier: GroupIdentifier) async throws {
        let tags: [[String]] = [["h", identifier.groupId]]

        guard let event = await NostrService.shared.signEventAsync(
            kind: 9008, content: "", tags: tags
        ) else {
            throw GroupError.signingFailed
        }

        publishToRelay(event, relayURL: identifier.relayURL)

        // The relay decides whether the group is really gone, but there is
        // nothing left to show here either way, so drop it locally exactly as
        // leaving does.
        ConfigService.shared.config.joinedGroups.removeAll {
            $0.relayURL == identifier.relayURL && $0.groupId == identifier.groupId
        }
        ConfigService.shared.save()

        conversations.removeAll { $0.identifier == identifier }
        saveConversations()
    }

    func createInvite(forGroup identifier: GroupIdentifier) async throws {
        let tags: [[String]] = [["h", identifier.groupId]]

        guard let event = await NostrService.shared.signEventAsync(
            kind: 9009, content: "", tags: tags
        ) else {
            throw GroupError.signingFailed
        }

        publishToRelay(event, relayURL: identifier.relayURL)
    }

    // MARK: - Helpers

    func markRead(group identifier: GroupIdentifier) {
        guard let idx = conversations.firstIndex(where: { $0.identifier == identifier }) else { return }
        conversations[idx].unreadCount = 0
        saveConversations()
    }

    func markAllAsRead() {
        for idx in conversations.indices {
            conversations[idx].unreadCount = 0
        }
        saveConversations()
    }

    func isAdmin(in identifier: GroupIdentifier) -> Bool {
        guard let conv = conversations.first(where: { $0.identifier == identifier }) else { return false }
        return conv.admins.contains(where: { $0.pubkey == loadedAccountPubkey })
    }

    // MARK: - Publishing

    private func publishToRelay(_ event: NostrEvent, relayURL: String) {
        guard let client = relayClients[relayURL] else { return }
        let eventDict = eventToDict(event)
        let msg = ["EVENT", eventDict] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
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

    private func sendREQ(_ subId: String, filter: [String: Any], to client: WebSocketClient) {
        let req = ["REQ", subId, filter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
    }

    private func urlSuffix(_ url: String) -> String {
        String(url.suffix(8).filter { $0.isLetter || $0.isNumber })
    }

    // MARK: - Throttling

    private func setupThrottling() {
        groupUpdateSubject
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private func sortConversations() {
        conversations.sort {
            ($0.lastMessage?.timestamp ?? .distantPast) > ($1.lastMessage?.timestamp ?? .distantPast)
        }
    }

    // MARK: - Account Switching

    private func handleAccountSwitch() {
        let newPubkey = NostrService.shared.activeHexPubkey
        guard newPubkey != loadedAccountPubkey else { return }

        switchGeneration &+= 1
        saveConversations()

        loadedAccountPubkey = newPubkey
        conversations = []
        availableGroups = []
        seenEventIds.removeAll()
        authenticatedRelays.removeAll()

        loadConversations()

        disconnectAll()
        connectToGroupRelays()
    }

    // MARK: - Persistence

    private func loadConversations() {
        let fileURL = cacheFileURL()
        guard let data = try? Data(contentsOf: fileURL) else { return }
        conversations = (try? JSONDecoder().decode([GroupConversation].self, from: data)) ?? []

        for conversation in conversations {
            for message in conversation.messages {
                seenEventIds.insert(message.id)
            }
        }
    }

    private func saveConversations() {
        let fileURL = cacheFileURL()
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? data.write(to: fileURL)
    }

    private func cacheFileURL() -> URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Haven")
        }
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        let key = loadedAccountPubkey
        let suffix = key.isEmpty ? "owner" : String(key.prefix(16))
        return havenDir.appendingPathComponent("group_cache_\(suffix).json")
    }

    // MARK: - Errors

    enum GroupError: LocalizedError {
        case noActiveAccount
        case signingFailed

        var errorDescription: String? {
            switch self {
            case .noActiveAccount: return "No active account"
            case .signingFailed: return "Failed to sign event"
            }
        }
    }
}
