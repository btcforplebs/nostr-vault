import SwiftUI
import Combine

struct ProfileView: View {
    let pubkey: String
    @EnvironmentObject var nostrService: NostrService
    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss

    @State private var showingNoteDetail: FeedNote?
    @State private var showLightning = false
    @State private var showAmountPicker = false
    @State private var zapAmountSats: String = ""
    @State private var copiedNpub = false

    // Swipe-to-dismiss
    @State private var dragOffset: CGFloat = 0

    // Note streaming
    @State private var profileNotes: [FeedNote] = []
    @State private var isLoadingNotes = false
    @State private var profileClients: [WebSocketClient] = []
    @State private var profileCancellables = Set<AnyCancellable>()
    @State private var seenNoteIds = Set<String>()

    private var isOwnProfile: Bool {
        nostrService.ownerHexPubkey == pubkey
    }

    private var isFollowing: Bool {
        feedService.followedPubkeys.contains(pubkey)
    }

    private var profile: FeedProfile? {
        nostrService.profiles[pubkey]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.havenPurple)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ScrollView {
                VStack(spacing: 16) {
                    profileHeader

                    if !isOwnProfile {
                        actionButtons
                    }

                    Rectangle()
                        .fill(Color.platformSeparator)
                        .frame(height: 0.5)
                        .padding(.horizontal, 16)

                    notesSection
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformWindowBackground)
        .offset(x: dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Only allow dragging to the right (positive x)
                    if value.translation.width > 0 {
                        dragOffset = value.translation.width
                    }
                }
                .onEnded { value in
                    if value.translation.width > 120 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .onAppear {
            if profile == nil {
                nostrService.fetchMissingProfiles(for: [pubkey])
            }
            fetchAuthorNotes()
        }
        .onDisappear {
            disconnectClients()
        }
        .sheet(item: $showingNoteDetail) { note in
            NavigationStack {
                NoteDetailView(note: note)
            }
        }
        .overlay {
            LightningAnimationView(isAnimating: $showLightning)
                .allowsHitTesting(false)
        }
        .alert("Zap Amount", isPresented: $showAmountPicker) {
            TextField("Amount in sats", text: $zapAmountSats)
            Button("Zap!") {
                if let amount = Int(zapAmountSats), let lud16 = lightningAddress {
                    Task { await zapProfile(lud16: lud16, amount: amount) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter the amount of sats you want to zap.")
        }
    }

    // MARK: - Profile Header

    private var profileHeader: some View {
        VStack(spacing: 12) {
            if let profile = profile {
                AvatarView(url: profile.pictureURL, pubkey: pubkey)
                    .frame(width: 80, height: 80)

                HStack(spacing: 6) {
                    Text(profile.bestName)
                        .font(.title2.bold())
                        .foregroundColor(.white)

                    if let nip05 = profile.nip05, !nip05.isEmpty {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.6))
                    }
                }

                if let nip05 = profile.nip05, !nip05.isEmpty {
                    Text(nip05)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                npubRow

                if let about = profile.about, !about.isEmpty {
                    Text(about)
                        .font(.system(size: 14))
                        .foregroundColor(Color(red: 0.85, green: 0.85, blue: 0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ProgressView()
                    .frame(height: 120)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Npub Row

    private var npubRow: some View {
        Button(action: copyNpub) {
            HStack(spacing: 4) {
                Text(formattedNpub)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                Image(systemName: copiedNpub ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundColor(copiedNpub ? .green : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: toggleFollow) {
                HStack(spacing: 6) {
                    Image(systemName: isFollowing ? "person.badge.minus" : "person.badge.plus")
                        .font(.system(size: 14, weight: .medium))
                    Text(isFollowing ? "Unfollow" : "Follow")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(isFollowing ? .white : .havenPurple)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isFollowing ? Color.havenPurple : Color.clear)
                .cornerRadius(20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.havenPurple, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)

            if !ConfigService.shared.config.nwcURI.isEmpty, lightningAddress != nil {
                Button(action: {
                    if let lud16 = lightningAddress {
                        Task { await zapProfile(lud16: lud16) }
                    }
                }) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.orange)
                        .frame(width: 36, height: 36)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onLongPressGesture {
                    zapAmountSats = String(ConfigService.shared.config.defaultZapAmount / 1000)
                    showAmountPicker = true
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Notes Section

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notes")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.secondary)
                if isLoadingNotes {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
            .padding(.horizontal, 16)

            if profileNotes.isEmpty && !isLoadingNotes {
                VStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No notes found")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(profileNotes) { note in
                        FeedNoteRow(note: note, profile: profile, showParent: false)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showingNoteDetail = note
                            }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 16)
    }

    // MARK: - Note Streaming

    private func fetchAuthorNotes() {
        guard !isLoadingNotes else { return }
        isLoadingNotes = true

        // Merge any notes already in the feed
        let existing = feedService.notes.filter { $0.pubkey == pubkey && !$0.isReply }
        for note in existing {
            if !seenNoteIds.contains(note.id) {
                seenNoteIds.insert(note.id)
                profileNotes.append(note)
            }
        }
        profileNotes.sort { $0.createdAt > $1.createdAt }

        // Build relay URLs (local + external)
        var relayURLs: [URL] = []
        if RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting {
            let config = ConfigService.shared.config
            if let local = URL(string: config.nostrURL) {
                relayURLs.append(local)
            }
        }
        let feedRelays = ConfigService.shared.config.feedRelays
        let externalStrs = feedRelays.isEmpty ? [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://relay.nos.social"
        ] : feedRelays
        relayURLs.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        for url in relayURLs {
            let client = WebSocketClient()
            profileClients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [self] message in
                    self.handleProfileNoteMessage(message)
                }
                .store(in: &profileCancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let filter: [String: Any] = [
                            "kinds": [1, 30023],
                            "authors": [pubkey],
                            "limit": 50
                        ]
                        let req: [Any] = ["REQ", "profile-notes-\(UUID().uuidString.prefix(4))", filter]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &profileCancellables)

            client.connect(url: url)
        }

        // Timeout: stop loading spinner after 8 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            isLoadingNotes = false
        }
    }

    private func handleProfileNoteMessage(_ message: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EVENT", json.count >= 3,
           let eventDict = json[2] as? [String: Any],
           let eventData = try? JSONSerialization.data(withJSONObject: eventDict),
           let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData) {

            guard event.pubkey == pubkey else { return }
            guard !seenNoteIds.contains(event.id) else { return }
            seenNoteIds.insert(event.id)

            let note = FeedNote(
                id: event.id,
                pubkey: event.pubkey,
                content: event.content,
                createdAt: Date(timeIntervalSince1970: TimeInterval(event.created_at)),
                tags: event.tags,
                kind: event.kind
            )

            // Skip replies
            guard !note.isReply else { return }

            profileNotes.append(note)
            profileNotes.sort { $0.createdAt > $1.createdAt }

            // Ensure we have the profile
            if profile == nil {
                nostrService.fetchMissingProfiles(for: [pubkey])
            }
        } else if type == "EOSE" {
            isLoadingNotes = false
        }
    }

    private func disconnectClients() {
        for client in profileClients {
            client.disconnect()
        }
        profileClients.removeAll()
        profileCancellables.removeAll()
    }

    // MARK: - Helpers

    private var formattedNpub: String {
        if let data = Bech32.hexToData(pubkey),
           let npub = Bech32.encode(hrp: "npub", data: data) {
            return String(npub.prefix(12)) + "…" + String(npub.suffix(8))
        }
        return "npub…" + String(pubkey.suffix(8))
    }

    private var lightningAddress: String? {
        guard let profile = profile else { return nil }
        if let lud16 = profile.lud16, !lud16.isEmpty { return lud16 }
        if let nip05 = profile.nip05, !nip05.isEmpty { return nip05 }
        return nil
    }

    private func copyNpub() {
        if let data = Bech32.hexToData(pubkey),
           let npub = Bech32.encode(hrp: "npub", data: data) {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(npub, forType: .string)
            #else
            UIPasteboard.general.string = npub
            #endif
            copiedNpub = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                copiedNpub = false
            }
        }
    }

    private func toggleFollow() {
        if isFollowing {
            feedService.unfollowUser(pubkey)
        } else {
            feedService.followUser(pubkey)
        }
    }

    private func zapProfile(lud16: String, amount: Int? = nil) async {
        do {
            try await ZapService.shared.zapNote(
                noteId: pubkey,
                notePubkey: pubkey,
                lud16: lud16,
                amountSats: amount
            )
            await MainActor.run {
                showLightning = true
            }
        } catch {
            #if DEBUG
            print("ProfileView: Zap failed: \(error)")
            #endif
        }
    }
}
