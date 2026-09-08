import SwiftUI
import Combine

// MARK: - Settings Tab View

struct FollowingBackupSettingsView: View {
    @ObservedObject private var feedService = FeedService.shared
    @ObservedObject private var backupService = FollowingBackupService.shared
    @ObservedObject private var configService = ConfigService.shared
    @ObservedObject private var nostrService = NostrService.shared

    @State private var selectedNpub: String = ""
    @State private var kind3Events: [Kind3Event] = []
    @State private var isQuerying = false
    @State private var queryStatus = ""
    @State private var relayClients: [WebSocketClient] = []
    @State private var queryCancellables = Set<AnyCancellable>()

    private var hasMultipleAccounts: Bool {
        configService.allAccountNpubs.count > 1
    }

    private var selectedSnapshotKey: String {
        selectedNpub == configService.config.ownerNpub ? "owner" : selectedNpub
    }

    private var selectedHexPubkey: String {
        Bech32.decode(selectedNpub)?.hexString ?? ""
    }

    private var isViewingActiveAccount: Bool {
        let activeNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveActive = activeNpub.isEmpty ? configService.config.ownerNpub : activeNpub
        return selectedNpub == effectiveActive
    }

    var body: some View {
        Form {
            if hasMultipleAccounts {
                Section {
                    ForEach(configService.allAccountNpubs, id: \.self) { npub in
                        let hex = Bech32.decode(npub)?.hexString ?? ""
                        let profile = nostrService.profiles[hex]
                        let isOwner = npub == configService.config.ownerNpub
                        let displayName = profile?.bestName ?? (isOwner ? "Owner" : String(npub.prefix(12)) + "...")
                        let isSelected = npub == selectedNpub

                        Button(action: { switchToAccount(npub) }) {
                            HStack(spacing: 10) {
                                AvatarView(url: profile?.pictureURL, pubkey: hex, size: 30)
                                Text(displayName)
                                    .font(.appSubheadline)
                                    .lineLimit(1)
                                if isOwner {
                                    Text("Owner")
                                        .font(.appCaption2)
                                        .fontWeight(.bold)
                                        .foregroundColor(.havenPurple)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.havenPurple.opacity(0.15))
                                        .cornerRadius(4)
                                }
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.appSubheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.havenPurple)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                    }
                } header: {
                    Text("Account")
                }
            }

            Section {
                if isQuerying {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(queryStatus)
                            .font(.appSubheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if kind3Events.isEmpty && !isQuerying {
                    Text("Tap \"Scan Relays\" to search for historical contact lists.")
                        .font(.appSubheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                }

                if !kind3Events.isEmpty {
                    ForEach(kind3Events) { event in
                        NavigationLink(destination: Kind3EventDetailView(event: event, isActiveAccount: isViewingActiveAccount)) {
                            kind3Row(event)
                        }
                    }
                }

                Button(action: queryRelaysForKind3) {
                    HStack(spacing: 6) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text(kind3Events.isEmpty ? "Scan Relays" : "Rescan Relays")
                    }
                }
                .disabled(isQuerying)
            } header: {
                Text("Recover Following List")
            } footer: {
                Text("Queries your local relay and external relays for all historical contact list events. Select one to view or restore.")
            }

            if !backupService.snapshots.isEmpty {
                Section {
                    ForEach(backupService.snapshots.reversed()) { snapshot in
                        NavigationLink(destination: SnapshotDetailView(snapshot: snapshot, isActiveAccount: isViewingActiveAccount)) {
                            snapshotRow(snapshot)
                        }
                    }
                    .onDelete { offsets in
                        deleteSnapshots(at: offsets)
                    }
                } header: {
                    Text("Automatic Backups")
                } footer: {
                    Text("Snapshots are saved automatically when your following list changes. Up to 50 are kept.")
                }
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if selectedNpub.isEmpty {
                let activeNpub = configService.config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
                selectedNpub = activeNpub.isEmpty ? configService.config.ownerNpub : activeNpub
                backupService.loadSnapshots(forAccountKey: selectedSnapshotKey)
            }
        }
    }

    // MARK: - Account Switching

    private func switchToAccount(_ npub: String) {
        guard npub != selectedNpub else { return }
        selectedNpub = npub

        // Reload snapshots for the new account
        backupService.loadSnapshots(forAccountKey: selectedSnapshotKey)

        // Clear relay scan results (they belong to the previous account)
        kind3Events = []
        queryStatus = ""

        // Cancel any in-progress relay queries
        if isQuerying {
            isQuerying = false
            for client in relayClients { client.disconnect() }
            relayClients = []
            queryCancellables.removeAll()
        }
    }

    // MARK: - Row Views

    private func kind3Row(_ event: Kind3Event) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.createdAt, style: .date)
                    .font(.appBody)
                HStack(spacing: 4) {
                    Text(event.createdAt, style: .time)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                    Text("\u{00b7}")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                    Text("\(event.followCount) following")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if isViewingActiveAccount {
                if Set(event.pubkeys) == Set(feedService.followedPubkeys) {
                    Text("Current")
                        .font(.appCaption2)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15))
                        .clipShape(Capsule())
                } else {
                    deltaLabel(snapshotCount: event.followCount, currentCount: feedService.followedPubkeys.count)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func snapshotRow(_ snapshot: FollowingSnapshot) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.capturedAt, style: .date)
                    .font(.appBody)
                HStack(spacing: 4) {
                    Text(snapshot.capturedAt, style: .time)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                    Text("\u{00b7}")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                    Text("\(snapshot.followCount) following")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if isViewingActiveAccount {
                deltaLabel(snapshotCount: snapshot.followCount, currentCount: feedService.followedPubkeys.count)
            }
        }
        .padding(.vertical, 2)
    }

    private func deltaLabel(snapshotCount: Int, currentCount: Int) -> some View {
        let diff = currentCount - snapshotCount
        return Group {
            if diff > 0 {
                Text("+\(diff)")
                    .font(.appCaption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
            } else if diff < 0 {
                Text("\(diff)")
                    .font(.appCaption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Relay Query

    private func queryRelaysForKind3() {
        isQuerying = true
        kind3Events = []
        queryCancellables.removeAll()

        // Disconnect any previous clients
        for client in relayClients { client.disconnect() }
        relayClients = []

        let ownerHex = selectedHexPubkey
        guard !ownerHex.isEmpty else {
            queryStatus = "No active account"
            isQuerying = false
            return
        }

        // Build relay list: local relay + external feed relays
        var relayURLs: [URL] = []
        if let localURL = URL(string: ConfigService.shared.config.nostrURL),
           RelayProcessManager.shared.isRunning, !RelayProcessManager.shared.isBooting {
            relayURLs.append(localURL)
        }
        let feedRelays = ConfigService.shared.config.activeFeedRelays
        let externalStrs = feedRelays.isEmpty ? [
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : feedRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        queryStatus = "Querying \(relayURLs.count) relay\(relayURLs.count == 1 ? "" : "s")..."

        var eoseCount = 0
        var seenIds = Set<String>()
        var collected: [Kind3Event] = []

        // Timeout after 15 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [self] in
            guard isQuerying else { return }
            finishQuery(collected: collected)
        }

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true
            relayClients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [self] msg in
                    guard isQuerying else { return }
                    guard let data = msg.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let type = json[0] as? String else { return }

                    if type == "EVENT", json.count >= 3,
                       let eventDict = json[2] as? [String: Any],
                       let kind = eventDict["kind"] as? Int, kind == 3,
                       let eventId = eventDict["id"] as? String,
                       !seenIds.contains(eventId),
                       let tags = eventDict["tags"] as? [[String]],
                       let createdAt = eventDict["created_at"] as? Int {
                        seenIds.insert(eventId)
                        let pTags = tags.filter { $0.count >= 2 && $0[0] == "p" }
                        let content = eventDict["content"] as? String ?? ""
                        let event = Kind3Event(
                            id: eventId,
                            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                            pubkeys: pTags.map { $0[1] },
                            pTags: pTags,
                            content: content
                        )
                        collected.append(event)
                        // Update UI live as events come in
                        kind3Events = collected.sorted { $0.createdAt > $1.createdAt }
                        queryStatus = "Found \(collected.count) event\(collected.count == 1 ? "" : "s")..."
                    } else if type == "EOSE" {
                        eoseCount += 1
                        if eoseCount >= relayURLs.count {
                            finishQuery(collected: collected)
                        }
                    }
                }
                .store(in: &queryCancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    guard state == .connected else { return }
                    // Request ALL Kind 3 events (no limit)
                    let filter: [String: Any] = ["kinds": [3], "authors": [ownerHex]]
                    let req: [Any] = ["REQ", "k3-recovery-\(UUID().uuidString.prefix(4))", filter]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        client.send(text: str)
                    }
                }
                .store(in: &queryCancellables)

            client.connect(url: url)
        }
    }

    private func finishQuery(collected: [Kind3Event]) {
        guard isQuerying else { return }
        isQuerying = false
        kind3Events = collected.sorted { $0.createdAt > $1.createdAt }
        queryStatus = collected.isEmpty ? "No events found" : "Found \(collected.count) event\(collected.count == 1 ? "" : "s")"
        for client in relayClients { client.disconnect() }
        relayClients = []
        queryCancellables.removeAll()
    }

    // MARK: - Snapshot Deletion

    private func deleteSnapshots(at offsets: IndexSet) {
        // offsets are into the reversed array
        let reversed = backupService.snapshots.reversed().map { $0 }
        let key = selectedSnapshotKey
        for index in offsets {
            let snapshot = reversed[index]
            backupService.deleteSnapshot(id: snapshot.id, forAccountKey: key)
        }
    }
}

// MARK: - Kind 3 Event Detail View (Recovery)

struct Kind3EventDetailView: View {
    let event: Kind3Event
    var isActiveAccount: Bool = true
    @ObservedObject private var feedService = FeedService.shared
    @State private var showRestoreAlert = false
    @State private var restoredPubkeys = Set<String>()

    private var currentSet: Set<String> { Set(feedService.followedPubkeys) }
    private var removedPubkeys: [String] { event.pubkeys.filter { !currentSet.contains($0) } }
    private var addedPubkeys: [String] { feedService.followedPubkeys.filter { !Set(event.pubkeys).contains($0) } }

    var body: some View {
        Form {
            Section {
                LabeledContent("Date", value: event.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Following", value: "\(event.followCount)")
                if isActiveAccount {
                    LabeledContent("Current", value: "\(feedService.followedPubkeys.count)")
                }
            } header: {
                Text("Summary")
            }

            if isActiveAccount && event.followCount > 0 && Set(event.pubkeys) != currentSet {
                Section {
                    Button(action: { showRestoreAlert = true }) {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.counterclockwise")
                            Text("Restore This List")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .foregroundColor(.white)
                    .listRowBackground(Color.havenPurple)
                }
            }

            if isActiveAccount && !removedPubkeys.isEmpty {
                Section {
                    ForEach(removedPubkeys, id: \.self) { pubkey in
                        profileRow(pubkey: pubkey, trailing: {
                            if restoredPubkeys.contains(pubkey) || currentSet.contains(pubkey) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            } else {
                                Button("Re-follow") {
                                    let result = feedService.followUser(pubkey)
                                    if case .success = result {
                                        restoredPubkeys.insert(pubkey)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        })
                    }
                } header: {
                    Text("No Longer Following (\(removedPubkeys.count))")
                } footer: {
                    Text("People in this backup that you no longer follow.")
                }
            }

            if isActiveAccount && !addedPubkeys.isEmpty {
                Section {
                    ForEach(addedPubkeys, id: \.self) { pubkey in
                        profileRow(pubkey: pubkey, trailing: {
                            Text("New")
                                .font(.appCaption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.12))
                                .clipShape(Capsule())
                        })
                    }
                } header: {
                    Text("Added Since (\(addedPubkeys.count))")
                } footer: {
                    Text("People you follow now that were not in this backup.")
                }
            }
        }
        .groupedFormStyleCompat()
        .navigationTitle("Contact List Backup")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Restore Contact List?", isPresented: $showRestoreAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Restore", role: .destructive) {
                feedService.restoreContactList(pTags: event.pTags, content: event.content)
            }
        } message: {
            Text("This will replace your current \(feedService.followedPubkeys.count) follows with \(event.followCount) follows from this backup and publish the updated list to your relays.")
        }
        .onAppear {
            guard isActiveAccount else { return }
            // Fetch profiles for all pubkeys we'll display
            let allPubkeys = removedPubkeys + addedPubkeys
            if !allPubkeys.isEmpty {
                NostrService.shared.fetchMissingProfiles(for: allPubkeys)
            }
        }
    }

    @ViewBuilder
    private func profileRow<T: View>(pubkey: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 10) {
            let profile = NostrService.shared.profiles[pubkey]
            AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile?.bestName ?? abbreviatedKey(pubkey))
                    .font(.appSubheadline)
                    .lineLimit(1)
                if let nip05 = profile?.nip05, !nip05.isEmpty {
                    Text(nip05)
                        .font(.appCaption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 2)
    }

    private func abbreviatedKey(_ hex: String) -> String {
        guard hex.count > 12 else { return hex }
        return String(hex.prefix(8)) + "..." + String(hex.suffix(4))
    }
}

// MARK: - Snapshot Detail View (Local Backups)

struct SnapshotDetailView: View {
    let snapshot: FollowingSnapshot
    var isActiveAccount: Bool = true
    @ObservedObject private var feedService = FeedService.shared
    @State private var showRestoreAlert = false
    @State private var restoredPubkeys = Set<String>()

    private var currentSet: Set<String> { Set(feedService.followedPubkeys) }
    private var removedPubkeys: [String] { snapshot.pubkeys.filter { !currentSet.contains($0) } }
    private var addedPubkeys: [String] { feedService.followedPubkeys.filter { !Set(snapshot.pubkeys).contains($0) } }

    var body: some View {
        Form {
            Section {
                LabeledContent("Date", value: snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Following", value: "\(snapshot.followCount)")
                if isActiveAccount {
                    LabeledContent("Current", value: "\(feedService.followedPubkeys.count)")
                }
            } header: {
                Text("Summary")
            }

            if isActiveAccount && snapshot.followCount > 0 && Set(snapshot.pubkeys) != currentSet {
                Section {
                    Button(action: { showRestoreAlert = true }) {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.counterclockwise")
                            Text("Restore This List")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .foregroundColor(.white)
                    .listRowBackground(Color.havenPurple)
                }
            }

            if isActiveAccount && !removedPubkeys.isEmpty {
                Section {
                    ForEach(removedPubkeys, id: \.self) { pubkey in
                        profileRow(pubkey: pubkey, trailing: {
                            if restoredPubkeys.contains(pubkey) || currentSet.contains(pubkey) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            } else {
                                Button("Re-follow") {
                                    let result = feedService.followUser(pubkey)
                                    if case .success = result {
                                        restoredPubkeys.insert(pubkey)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        })
                    }
                } header: {
                    Text("No Longer Following (\(removedPubkeys.count))")
                } footer: {
                    Text("People in this backup that you no longer follow.")
                }
            }

            if isActiveAccount && !addedPubkeys.isEmpty {
                Section {
                    ForEach(addedPubkeys, id: \.self) { pubkey in
                        profileRow(pubkey: pubkey, trailing: {
                            Text("New")
                                .font(.appCaption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.12))
                                .clipShape(Capsule())
                        })
                    }
                } header: {
                    Text("Added Since (\(addedPubkeys.count))")
                } footer: {
                    Text("People you follow now that were not in this backup.")
                }
            }
        }
        .groupedFormStyleCompat()
        .navigationTitle("Snapshot Backup")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Restore Contact List?", isPresented: $showRestoreAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Restore", role: .destructive) {
                feedService.restoreContactList(pTags: snapshot.pTags, content: snapshot.contactListContent)
            }
        } message: {
            Text("This will replace your current \(feedService.followedPubkeys.count) follows with \(snapshot.followCount) follows from this snapshot and publish the updated list to your relays.")
        }
        .onAppear {
            guard isActiveAccount else { return }
            let allPubkeys = removedPubkeys + addedPubkeys
            if !allPubkeys.isEmpty {
                NostrService.shared.fetchMissingProfiles(for: allPubkeys)
            }
        }
    }

    @ViewBuilder
    private func profileRow<T: View>(pubkey: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 10) {
            let profile = NostrService.shared.profiles[pubkey]
            AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile?.bestName ?? abbreviatedKey(pubkey))
                    .font(.appSubheadline)
                    .lineLimit(1)
                if let nip05 = profile?.nip05, !nip05.isEmpty {
                    Text(nip05)
                        .font(.appCaption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 2)
    }

    private func abbreviatedKey(_ hex: String) -> String {
        guard hex.count > 12 else { return hex }
        return String(hex.prefix(8)) + "..." + String(hex.suffix(4))
    }
}
