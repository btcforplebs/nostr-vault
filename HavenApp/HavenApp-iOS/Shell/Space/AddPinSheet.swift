import SwiftUI
import Combine

/// Pins a favourite to the iPad rail: one of your lists, a person (from the
/// people you follow, or an npub), a hashtag or a relay.
struct AddPinSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case list = "List", person = "Person", hashtag = "Hashtag", relay = "Relay"
        var id: String { rawValue }
    }

    @ObservedObject private var store = SpaceLayoutStore.shared
    @ObservedObject private var feedService = FeedService.shared
    @ObservedObject private var interests = InterestListService.shared
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var lists = OwnListsFetcher()
    @State private var kind: Kind = .list
    @State private var text = ""
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                switch kind {
                case .list: listRows
                case .person: personRows
                case .hashtag: hashtagRows
                case .relay: relayRows
                }
            }
            .navigationTitle("Add to rail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: kind) { _, _ in text = ""; notice = nil }
            .task { lists.start(owner: configService.activeAccountHexPubkey.lowercased()) }
            .onDisappear { lists.stop() }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var listRows: some View {
        Section("Your lists") {
            if lists.lists.isEmpty {
                Text(lists.isLoading ? "Looking for your lists..." : "You have no people lists yet. Lists made in other Nostr apps show here.")
                    .foregroundColor(.secondary)
            }
            ForEach(lists.lists, id: \.address) { list in
                pinRow(.list(list.address), name: list.title, title: list.title,
                       subtitle: "\(list.count) \(list.count == 1 ? "person" : "people")", symbol: "person.3")
            }
        }
    }

    @ViewBuilder
    private var personRows: some View {
        Section {
            TextField("npub or hex key", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(pinTypedPerson)
        } footer: { Text("Or pick someone you follow below.") }
        Section("People you follow") {
            let matches = followMatches
            if matches.isEmpty { Text("No one matches").foregroundColor(.secondary) }
            ForEach(matches, id: \.self) { pk in
                let name = nostrService.profiles[pk]?.bestName
                pinRow(.person(pk), name: name, title: name ?? String(pk.prefix(12)), subtitle: nil, avatar: pk)
            }
        }
    }

    @ViewBuilder
    private var hashtagRows: some View {
        Section {
            TextField("#hashtag", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { pin(.hashtag(text), name: nil) }
        }
        if !interests.hashtags.isEmpty {
            Section("Hashtags you follow") {
                ForEach(interests.hashtags, id: \.self) { tag in
                    pinRow(.hashtag(tag), name: nil, title: "#\(tag)", subtitle: nil, symbol: "number")
                }
            }
        }
    }

    @ViewBuilder
    private var relayRows: some View {
        Section {
            TextField("wss://relay.example.com", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onSubmit { pin(.relay(text), name: nil) }
        }
        Section("Your relays") {
            ForEach(yourRelays, id: \.self) { url in
                pinRow(.relay(url), name: nil, title: URL(string: url)?.host ?? url, subtitle: url,
                       symbol: "antenna.radiowaves.left.and.right")
            }
        }
    }

    private func pinRow(_ kind: SpaceLayout.Pin.Kind, name: String?, title: String, subtitle: String?,
                        symbol: String = "", avatar: String? = nil) -> some View {
        let pinned = store.isPinned(kind)
        return Button { pin(kind, name: name) } label: {
            HStack(spacing: 12) {
                if let avatar {
                    AvatarView(url: nostrService.profiles[avatar]?.pictureURL, pubkey: avatar, size: 30)
                } else {
                    Image(systemName: symbol).foregroundColor(.havenPurple).frame(width: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundColor(.primary).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.appCaption).foregroundColor(.secondary).lineLimit(1) }
                }
                Spacer()
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundColor(pinned ? .havenPurple : .secondary)
            }
        }
        .disabled(pinned)
        .accessibilityLabel(pinned ? "\(title), on the rail" : "Pin \(title)")
    }

    // MARK: Data

    private var followMatches: [String] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        let follows = feedService.followedPubkeys
        let named = follows.filter { pk in
            guard !q.isEmpty else { return true }
            return (nostrService.profiles[pk]?.bestName.lowercased().contains(q) ?? false) || pk.hasPrefix(q)
        }
        return Array(named.sorted {
            (nostrService.profiles[$0]?.bestName ?? "~").localizedCaseInsensitiveCompare(nostrService.profiles[$1]?.bestName ?? "~") == .orderedAscending
        }.prefix(50))
    }

    private var yourRelays: [String] {
        var seen = Set<String>()
        return (configService.config.readRelays + configService.config.activeFeedRelays).compactMap {
            SpaceLayout.normaliseRelay($0)
        }.filter { seen.insert($0).inserted && !NostrService.isLoopbackRelay($0) }
    }

    private func pinTypedPerson() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = raw.hasPrefix("npub1") ? (Bech32.decode(raw)?.hexString ?? "") : raw
        pin(.person(hex), name: nil)
    }

    private func pin(_ kind: SpaceLayout.Pin.Kind, name: String?) {
        guard let pin = SpaceLayout.Pin.favourite(kind, name: name) else {
            notice = "That doesn't look like a valid one."
            return
        }
        if store.isPinned(kind) { notice = "It's already on your rail."; return }
        if store.addPin(pin) {
            dismiss()
        } else {
            notice = "Your rail is full (\(SpaceLayout.maxFavourites) favourites). Remove one first."
        }
    }
}

/// The account's own NIP-51 people lists (follow sets, kind 30000, and follow
/// packs, 39089), newest version of each, from its relays.
@MainActor
final class OwnListsFetcher: ObservableObject {
    struct OwnList {
        let address: String
        let title: String
        let count: Int
        let createdAt: Int64
    }

    @Published private(set) var lists: [OwnList] = []
    @Published private(set) var isLoading = true
    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()

    func start(owner: String) {
        stop()
        guard !owner.isEmpty else { isLoading = false; return }
        let config = ConfigService.shared.config
        var relays: [String] = []
        for url in config.writeRelays + config.readRelays where !relays.contains(url) { relays.append(url) }
        let subId = "lists-\(UUID().uuidString.prefix(8))"
        let filter: [String: Any] = ["kinds": [30000, 39089], "authors": [owner], "limit": 100]
        guard let data = try? JSONSerialization.data(withJSONObject: ["REQ", subId, filter] as [Any]),
              let req = String(data: data, encoding: .utf8) else { return }
        var newest: [String: OwnList] = [:]
        for url in relays.compactMap(URL.init(string:)) {
            let client = WebSocketClient()
            client.isTemporary = true
            clients.append(client)
            var sent = false
            client.$connectionState
                .sink { [weak client] state in
                    guard state == .connected, !sent, let client else { return }
                    sent = true
                    client.send(text: req)
                }
                .store(in: &cancellables)
            client.messageSubject
                .compactMap { Self.parse($0, subId: subId, owner: owner) }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] parsed in
                    guard let self else { return }
                    guard let list = parsed else { self.isLoading = false; return }
                    if let old = newest[list.address], old.createdAt >= list.createdAt { return }
                    newest[list.address] = list
                    self.lists = newest.values.filter { $0.count > 0 }
                        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                }
                .store(in: &cancellables)
            client.connect(url: url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.isLoading = false }
    }

    func stop() {
        clients.forEach { $0.disconnect() }
        clients = []
        cancellables = []
    }

    /// An EVENT as a list (`.some(list)`), the EOSE (`.some(nil)`), else nil.
    nonisolated private static func parse(_ message: String, subId: String, owner: String) -> OwnList?? {
        guard let data = message.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = array.first as? String, array.count >= 2, (array[1] as? String) == subId else { return nil }
        if type == "EOSE" { return .some(nil) }
        guard type == "EVENT", array.count >= 3, let ev = array[2] as? [String: Any],
              let pubkey = ev["pubkey"] as? String, pubkey.lowercased() == owner,
              let kind = ev["kind"] as? Int, kind == 30000 || kind == 39089,
              let createdAt = ev["created_at"] as? Int64,
              let tags = ev["tags"] as? [[String]],
              let d = tags.first(where: { $0.count >= 2 && $0[0] == "d" })?[1], !d.isEmpty,
              NostrEventVerifier.isValid(ev) else { return nil }
        let title = tags.first { $0.count >= 2 && ($0[0] == "title" || $0[0] == "name") }?[1] ?? d
        let count = Set(tags.filter { $0.count >= 2 && $0[0] == "p" }.map { $0[1] }).count
        return .some(OwnList(address: "\(kind):\(owner):\(d)", title: title, count: count, createdAt: createdAt))
    }
}
