import SwiftUI
import Combine
#if os(iOS)
import Photos
#endif

struct ProfileView: View {
    let pubkey: String
    var embeddedInNavigation: Bool = false
    var onDismiss: (() -> Void)? = nil

    @EnvironmentObject var nostrService: NostrService
    @StateObject private var feedService = FeedService.shared
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showingNoteDetail: FeedNote?
    @State private var showingProfileKey: IdentifiableString?
    @State private var showingMediaUrl: IdentifiableURL?
    @State private var selectedMedia: MediaItem? = nil
    @State private var dragOffset: CGSize = .zero
    #if os(iOS)
    @State private var saveToPhotosMessage: String? = nil
    #endif
    #if os(macOS)
    @State private var keyMonitor: Any? = nil
    #endif
    
    @State private var showSweep = false
    @State private var showLightning = false
    @State private var showAmountPicker = false
    @State private var zapAmountSats: String = ""
    @State private var copiedNpub = false
    @State private var copiedLightning = false
    @State private var copiedBitcoinAddress = false
    @State private var copiedSPAddress = false

    // Bitcoin on-chain
    @State private var bitcoinBalance: Int? = nil
    @State private var bitcoinAddress: String? = nil

    // Silent Payment address
    @State private var silentPaymentAddress: String? = nil

    // Lightning (NWC) balance — own profile only
    @State private var lightningBalanceSats: Int? = nil
    @State private var isLoadingLightningBalance = false

    // Edit profile
    @State private var showingEditProfile = false

    // Compose post
    @State private var showingCompose = false

    // Message composer
    @State private var showingMessageComposer = false

    // DM inbox
    @State private var showingDMInbox = false

    // Wallet views
    @State private var showingOnChain = false
    @State private var showingLightning = false

    // Following / followers count
    @State private var followingCount: Int? = nil
    @State private var followsMe: Bool = false
    @State private var followersCount: Int? = nil
    @State private var followerPubkeys = Set<String>()

    // Note streaming
    @State private var profileNotes: [FeedNote] = []
    @State private var isLoadingNotes = false
    @State private var profileClients: [WebSocketClient] = []
    @State private var profileCancellables = Set<AnyCancellable>()
    @State private var seenNoteIds = Set<String>()

    @State private var selectedSection: ProfileSection = .notes

    enum ProfileSection: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case media = "Media"
        case replies = "Replies"
        var id: String { rawValue }
    }

    private var isOwnProfile: Bool {
        nostrService.activeHexPubkey == pubkey
    }

    // NWC wallet belongs to the owner only — don't re-fetch balance for whitelisted accounts.
    private var isOwnerProfile: Bool {
        Bech32.decode(configService.config.ownerNpub)?.hexString == pubkey
    }

    private var isFollowing: Bool {
        feedService.followedPubkeys.contains(pubkey)
    }

    private var profile: FeedProfile? {
        nostrService.profiles[pubkey]
    }

    private var defaultZapSats: Int {
        max(1, ConfigService.shared.config.defaultZapAmount / 1000)
    }

    // MARK: - Filtered notes for tabs

    private var topNotes: [FeedNote] {
        profileNotes.filter { !$0.isReply }
    }

    private var mediaNotes: [FeedNote] {
        profileNotes.filter { !$0.mediaURLs.isEmpty && !$0.isReply }
    }

    private var replyNotes: [FeedNote] {
        profileNotes.filter { $0.isReply }
    }

    private var currentSectionNotes: [FeedNote] {
        switch selectedSection {
        case .notes: return topNotes
        case .media: return mediaNotes
        case .replies: return replyNotes
        }
    }

    private var displayMedia: [MediaItem] {
        let items: [(url: URL, note: FeedNote)] = mediaNotes.flatMap { note in
            note.mediaURLs.map { (url: $0, note: note) }
        }
        return items.map { item in
            let ext = item.url.pathExtension.lowercased()
            var isGIF = ext == "gif"
            var isVideo = ["mp4", "mov", "webm", "m4v", "hevc", "h265"].contains(ext)
            var isAudio = ["mp3", "wav", "ogg", "m4a", "flac"].contains(ext)
            
            if let cachedMime = MediaTypeDetector.shared.getCachedContentType(for: item.url) {
                isGIF = MediaTypeDetector.shared.isGIFContentType(cachedMime)
                isVideo = MediaTypeDetector.shared.isVideoContentType(cachedMime)
                isAudio = cachedMime.lowercased().hasPrefix("audio/")
            }
            
            let type: MediaItem.MediaType = isVideo ? .video : (isAudio ? .audio : .image)
            let mime = isGIF ? "image/gif" : (isVideo ? "video/mp4" : nil)
            
            return MediaItem(
                id: UUID.deterministic(from: item.url.absoluteString),
                url: item.url,
                type: type,
                dateAdded: item.note.createdAt,
                pubkey: item.note.pubkey,
                tags: item.note.tags,
                mimeType: mime
            )
        }
    }

    private var isPresentingViewer: Binding<Bool> {
        Binding(
            get: { selectedMedia != nil },
            set: { presenting in
                if !presenting {
                    selectedMedia = nil
                    dragOffset = .zero
                }
            }
        )
    }

    private var sectionCount: (notes: Int, media: Int, replies: Int) {
        (topNotes.count, mediaNotes.count, replyNotes.count)
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !embeddedInNavigation && !isOwnProfile {
                    dismissHeader
                }
                headerBlock
                actionRow
                    .padding(.top, 4)
                if let about = profile?.about, !about.isEmpty {
                    bioBlock(about)
                }
                divider
                statsBlock
                activityRow
                divider
                identityBlock
                divider
                sectionTabBar
                sectionContent
                    #if os(iOS)
                    .padding(.bottom, 90)
                    #else
                    .padding(.bottom, 32)
                    #endif
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            await refreshProfile()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.08, green: 0.08, blue: 0.1).ignoresSafeArea())
        .onAppear {
            nostrService.fetchMissingProfiles(for: [pubkey], force: true)
            fetchAuthorNotes()
            deriveBitcoinAddress()
            deriveSilentPaymentAddress()
            fetchLightningBalance()
            #if os(macOS)
            installKeyMonitor()
            #endif
        }
        .onDisappear {
            disconnectClients()
            #if os(macOS)
            removeKeyMonitor()
            #endif
        }
        .sheet(item: $showingNoteDetail) { note in
            NavigationStack {
                NoteDetailView(note: note)
                    .navigationDestination(for: FeedNote.self) { detailNote in
                        NoteDetailView(note: detailNote)
                    }
            }
        }
        .sheet(item: $showingProfileKey) { p in
            ProfileView(pubkey: p.id, onDismiss: { showingProfileKey = nil })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(item: $showingMediaUrl) { media in
            FeedMediaViewer(url: media.url, onDismiss: { showingMediaUrl = nil })
        }
        .sheet(isPresented: $showSweep) {
            BitcoinSweepDisclaimerView(onDismiss: { showSweep = false })
                .environmentObject(ConfigService.shared)
        }
        .sheet(isPresented: $showingOnChain) {
            NavigationStack {
                WalletOnChainTab()
                    .environmentObject(nostrService)
                    .environmentObject(configService)
                    .navigationTitle("On-Chain")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingOnChain = false }
                                .foregroundColor(.havenPurple)
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 500, minHeight: 550)
            #endif
        }
        .sheet(isPresented: $showingLightning) {
            NavigationStack {
                WalletLightningTab()
                    .environmentObject(nostrService)
                    .environmentObject(configService)
                    .navigationTitle("Lightning")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingLightning = false }
                                .foregroundColor(.havenPurple)
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 500, minHeight: 550)
            #endif
        }
        .sheet(isPresented: $showingCompose) {
            ComposeView(onDismiss: { showingCompose = false })
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                if isOwnProfile {
                    Button(action: { showingOnChain = true }) {
                        Image(systemName: "bitcoinsign.circle.fill")
                            .foregroundColor(.orange)
                    }
                    Button(action: { showingLightning = true }) {
                        Image(systemName: "bolt.fill")
                            .foregroundColor(.yellow)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if isOwnProfile {
                    Button(action: { showingDMInbox = true }) {
                        Image(systemName: "bubble.right.fill")
                            .foregroundColor(.havenPurple)
                    }
                } else {
                    Button(action: { showingMessageComposer = true }) {
                        Image(systemName: "message.fill")
                            .foregroundColor(.havenPurple)
                    }
                }
            }
        }
        .sheet(isPresented: $showingMessageComposer) {
            MessageComposerView(recipientPubkey: pubkey)
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingDMInbox) {
            NavigationStack {
                DMInboxView()
                    .environmentObject(nostrService)
                    .environmentObject(configService)
            }
        }
        #else
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if isOwnProfile {
                    Button(action: { showingOnChain = true }) {
                        Image(systemName: "bitcoinsign.circle.fill")
                            .foregroundColor(.orange)
                    }
                    .help("On-Chain")
                }
            }
            ToolbarItem(placement: .automatic) {
                if isOwnProfile {
                    Button(action: { showingLightning = true }) {
                        Image(systemName: "bolt.fill")
                            .foregroundColor(.yellow)
                    }
                    .help("Lightning")
                }
            }
            ToolbarItem(placement: .automatic) {
                if isOwnProfile {
                    Button(action: { showingDMInbox = true }) {
                        Image(systemName: "bubble.right.fill")
                            .foregroundColor(.havenPurple)
                    }
                    .help("Messages")
                }
            }
        }
        .sheet(isPresented: $showingDMInbox) {
            DMInboxView()
                .environmentObject(nostrService)
                .environmentObject(configService)
                .frame(minWidth: 480, minHeight: 500)
        }
        .sheet(isPresented: $showingMessageComposer) {
            DMThreadView(counterpartyPubkey: pubkey)
                .environmentObject(nostrService)
                .environmentObject(configService)
                .frame(minWidth: 440, minHeight: 400)
        }
        #endif
        .sheet(isPresented: $showingEditProfile) {
            ProfileEditView(onDismiss: { showingEditProfile = false }, existing: profile ?? FeedProfile(pubkey: pubkey)) { updated in
                applyProfileUpdate(updated)
            }
            .environmentObject(nostrService)
        }
        .overlay {
            LightningAnimationView(isAnimating: $showLightning)
                .allowsHitTesting(false)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: isPresentingViewer) {
            if let item = selectedMedia {
                mediaViewerContent(for: item)
            }
        }
        #else
        .overlay(fullScreenOverlay)
        #endif
        .alert("Zap Amount", isPresented: $showAmountPicker) {
            #if os(iOS)
            TextField("Amount in sats", text: $zapAmountSats)
                .keyboardType(.numberPad)
            #else
            TextField("Amount in sats", text: $zapAmountSats)
            #endif
            Button("Zap!") {
                if let amount = Int(zapAmountSats), let lud16 = lightningAddress {
                    Task { await zapProfile(lud16: lud16, amount: amount) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter the amount of sats to zap.")
        }
    }

    // MARK: - Dismiss header (sheet context only)

    private var dismissHeader: some View {
        HStack {
            Spacer()
            Button(action: { performDismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary.opacity(0.55))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func performDismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.platformSeparator.opacity(0.6))
            .frame(height: 0.5)
            .padding(.vertical, 16)
    }

    // MARK: - Header block

    private var headerBlock: some View {
        HStack(alignment: .top, spacing: 14) {
            AvatarView(url: profile?.pictureURL, pubkey: pubkey)
                .frame(width: 64, height: 64)
                .overlay(
                    Circle().stroke(Color.havenPurple.opacity(0.35), lineWidth: 1.5)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile?.bestName ?? shortPubkey)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if let nip05 = profile?.nip05, !nip05.isEmpty {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13))
                            .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.6))
                    }

                    Spacer(minLength: 0)

                    statusBadge
                }

                if let nip05 = profile?.nip05, !nip05.isEmpty {
                    Text(nip05)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Button(action: copyNpub) {
                    HStack(spacing: 5) {
                        Text(formattedNpub)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Image(systemName: copiedNpub ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                            .foregroundColor(copiedNpub ? .green : .secondary.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isOwnProfile {
            Text("YOU")
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.8)
                .foregroundColor(.havenPurple)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.havenPurple.opacity(0.15))
                .cornerRadius(4)
        } else if isFollowing && followsMe {
            HStack(spacing: 3) {
                Text("∞")
                    .font(.system(size: 13, weight: .black))
                Text("MUTUAL")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
            }
            .foregroundColor(Color(red: 0.2, green: 0.9, blue: 0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(red: 0.2, green: 0.9, blue: 0.7).opacity(0.13))
            .cornerRadius(4)
        } else {
            HStack(spacing: 4) {
                if isFollowing {
                    Text("FOLLOWING")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.8)
                        .foregroundColor(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(4)
                }
                if followsMe {
                    Text("FOLLOWS YOU")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.8)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                }
            }
        }
    }

    // MARK: - Bio

    private func bioBlock(_ about: String) -> some View {
        Text(about)
            .font(.system(size: 13))
            .foregroundColor(.primary.opacity(0.85))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
    }

    // MARK: - Action row

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            if isOwnProfile {
                Button(action: { showingCompose = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Post")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.havenPurple)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(action: { showingEditProfile = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Edit")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.havenPurple)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.havenPurple.opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: toggleFollow) {
                    HStack(spacing: 6) {
                        Image(systemName: isFollowing ? "person.badge.minus" : "person.badge.plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text(isFollowing ? "Unfollow" : "Follow")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(isFollowing ? .white : .havenPurple)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(isFollowing ? Color.havenPurple : Color.havenPurple.opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(action: { showingMessageComposer = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "message.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Message")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.havenPurple)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.havenPurple.opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                if !ConfigService.shared.config.nwcURI.isEmpty, lightningAddress != nil {
                    Button(action: {
                        if let lud16 = lightningAddress {
                            Task { await zapProfile(lud16: lud16) }
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Zap \(defaultZapSats)")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.orange)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .onLongPressGesture {
                        zapAmountSats = String(defaultZapSats)
                        showAmountPicker = true
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Stats block

    private var statsBlock: some View {
        HStack(spacing: 0) {
            statCell(value: shortInt(sectionCount.notes), label: "NOTES")
            statDivider
            statCell(value: shortInt(sectionCount.media), label: "MEDIA")
            statDivider
            if isOwnProfile {
                statCell(
                    value: shortInt(feedService.followedPubkeys.filter { $0 != pubkey }.count),
                    label: "FOLLOWING"
                )
                statDivider
                statCell(
                    value: lightningBalanceSats.map(shortSats) ?? (isLoadingLightningBalance ? "…" : "—"),
                    label: "⚡ LIGHTNING",
                    tint: lightningBalanceSats != nil ? .orange : .secondary
                )
                statDivider
                statCell(
                    value: bitcoinBalance.map(shortSats) ?? "—",
                    label: "\u{20BF} ON-CHAIN",
                    tint: (bitcoinBalance ?? 0) > 0 ? .orange : .secondary
                )
            } else {
                statCell(
                    value: followingCount.map(shortInt) ?? "—",
                    label: "FOLLOWING"
                )
                statDivider
                statCell(
                    value: followersCount.map(shortInt) ?? "∞",
                    label: "FOLLOWERS",
                    tint: followersCount == nil ? Color(red: 0.2, green: 0.9, blue: 0.7).opacity(0.55) : .primary
                )
                statDivider
                if let bal = bitcoinBalance, bal > 0 {
                    statCell(value: shortSats(bal), label: "\u{20BF} ON-CHAIN", tint: .orange)
                } else {
                    statCell(value: "—", label: "\u{20BF} ON-CHAIN")
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.platformSeparator.opacity(0.4))
            .frame(width: 0.5)
            .padding(.vertical, 10)
    }

    private func statCell(value: String, label: String, tint: Color = .primary) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(tint)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Activity sparkline

    private var activityRow: some View {
        let buckets = activityBuckets(days: 14)
        let max = (buckets.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(buckets.enumerated()), id: \.offset) { _, count in
                let ratio = max > 0 ? CGFloat(count) / CGFloat(max) : 0
                RoundedRectangle(cornerRadius: 1)
                    .fill(count > 0 ? Color.havenPurple.opacity(0.4 + 0.6 * ratio) : Color.platformSeparator.opacity(0.4))
                    .frame(height: 4 + 22 * ratio)
                    .frame(maxWidth: .infinity)
            }

            Text("14d")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.leading, 6)
                .frame(width: 24, alignment: .trailing)
        }
        .frame(height: 30)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func activityBuckets(days: Int) -> [Int] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var buckets = Array(repeating: 0, count: days)
        for note in profileNotes {
            let day = calendar.startOfDay(for: note.createdAt)
            let diff = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            if diff >= 0 && diff < days {
                buckets[days - 1 - diff] += 1
            }
        }
        return buckets
    }

    // MARK: - Identity block (table-style rows)

    @ViewBuilder
    private var identityBlock: some View {
        VStack(spacing: 0) {
            if let lud16 = lightningAddress {
                identityRow(
                    label: "LIGHTNING",
                    value: lud16,
                    icon: "bolt.fill",
                    tint: .orange,
                    copied: copiedLightning,
                    trailing: zapInlineButton(lud16: lud16),
                    action: { copyToClipboard(lud16); triggerCopied($copiedLightning) }
                )
            }

            if let address = bitcoinAddress {
                identityDivider
                identityRow(
                    label: "BITCOIN",
                    value: formattedAddress(address),
                    icon: "bitcoinsign.circle.fill",
                    tint: Color(red: 1.0, green: 0.6, blue: 0.1),
                    copied: copiedBitcoinAddress,
                    trailing: bitcoinBalanceTrailing,
                    action: { copyToClipboard(address); triggerCopied($copiedBitcoinAddress) }
                )

                if isOwnProfile, let bal = bitcoinBalance, bal > 0 {
                    Button(action: { showSweep = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Sweep \(shortSats(bal)) sats to wallet")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(.orange)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.orange.opacity(0.08))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let spAddr = silentPaymentAddress {
                identityDivider
                identityRow(
                    label: "SILENT PAYMENT",
                    value: formattedAddress(spAddr),
                    icon: "eye.slash.fill",
                    tint: Color(red: 0.6, green: 0.4, blue: 1.0),
                    copied: copiedSPAddress,
                    trailing: AnyView(
                        Text("BETA")
                            .font(.system(size: 9, weight: .black))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red)
                            .cornerRadius(4)
                    ),
                    action: { copyToClipboard(spAddr); triggerCopied($copiedSPAddress) }
                )
            }

            if let website = profile?.website, !website.isEmpty,
               let url = URL(string: website.hasPrefix("http") ? website : "https://\(website)") {
                identityDivider
                Button(action: { openURL(url) }) {
                    identityRowContent(
                        label: "WEBSITE",
                        value: website.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""),
                        icon: "globe",
                        tint: .havenPurple,
                        copied: false,
                        trailing: AnyView(
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.havenPurple)
                        )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var identityDivider: some View {
        Rectangle()
            .fill(Color.platformSeparator.opacity(0.4))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private var bitcoinBalanceTrailing: AnyView {
        if let bal = bitcoinBalance, bal > 0 {
            return AnyView(
                Text("\(formatSats(bal))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.orange)
            )
        } else {
            return AnyView(EmptyView())
        }
    }

    private func zapInlineButton(lud16: String) -> AnyView {
        if isOwnerProfile {
            if let bal = lightningBalanceSats {
                return AnyView(
                    Text("\(shortSats(bal)) sats")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                )
            }
            return AnyView(EmptyView())
        }
        guard !ConfigService.shared.config.nwcURI.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            Button(action: {
                Task { await zapProfile(lud16: lud16) }
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("\(defaultZapSats)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundColor(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .onLongPressGesture {
                zapAmountSats = String(defaultZapSats)
                showAmountPicker = true
            }
        )
    }

    private func identityRow(label: String, value: String, icon: String, tint: Color, copied: Bool, trailing: AnyView, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            identityRowContent(label: label, value: value, icon: icon, tint: tint, copied: copied, trailing: trailing)
        }
        .buttonStyle(.plain)
    }

    private func identityRowContent(label: String, value: String, icon: String, tint: Color, copied: Bool, trailing: AnyView) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if copied {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.green)
            }

            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Section tab bar

    private var sectionTabBar: some View {
        HStack(spacing: 0) {
            ForEach(ProfileSection.allCases) { section in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedSection = section
                    }
                }) {
                    VStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Text(section.rawValue.uppercased())
                                .font(.system(size: 11, weight: .heavy))
                                .tracking(0.6)
                            Text(countLabel(for: section))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .foregroundColor(selectedSection == section ? .havenPurple : .secondary)

                        Rectangle()
                            .fill(selectedSection == section ? Color.havenPurple : Color.clear)
                            .frame(height: 2)
                    }
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private func count(for section: ProfileSection) -> Int {
        switch section {
        case .notes: return sectionCount.notes
        case .media: return sectionCount.media
        case .replies: return sectionCount.replies
        }
    }

    private func countLabel(for section: ProfileSection) -> String {
        let n = count(for: section)
        return n > 0 ? shortInt(n) : ""
    }

    // MARK: - Section content

    @ViewBuilder
    private var sectionContent: some View {
        let notes = currentSectionNotes
        if notes.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: sectionEmptyIcon)
                    .font(.system(size: 24, weight: .thin))
                    .foregroundColor(.secondary.opacity(0.5))
                Text(isLoadingNotes ? "Loading…" : "No \(selectedSection.rawValue.lowercased()) yet")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                if isLoadingNotes {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(Color.havenPurple)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else if selectedSection == .media {
            mediaGrid(notes: notes)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(notes.enumerated()), id: \.element.id) { idx, note in
                    if idx > 0 {
                        Rectangle()
                            .fill(Color.platformSeparator.opacity(0.4))
                            .frame(height: 0.5)
                            .padding(.leading, 16)
                    }
                    FeedNoteRow(
                        note: note,
                        profile: profile,
                        onProfile: { pubkey in
                            showingProfileKey = IdentifiableString(id: pubkey)
                        },
                        onMedia: { url in
                            showingMediaUrl = IdentifiableURL(url: url)
                        },
                        showParent: false
                    )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showingNoteDetail = note
                        }
                }
            }
            .padding(.top, 4)
        }
    }

    private func mediaGrid(notes: [FeedNote]) -> some View {
        #if os(macOS)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        let gridSpacing: CGFloat = 8
        #else
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
        let gridSpacing: CGFloat = 6
        #endif
        
        let items = displayMedia
        
        return LazyVGrid(columns: columns, spacing: gridSpacing) {
            ForEach(items) { mediaItem in
                MediaGridItem(item: mediaItem) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedMedia = mediaItem
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func mediaViewerContent(for item: MediaItem) -> some View {
        ZStack {
            Color.black.opacity(0.9 * max(0, 1.0 - (abs(dragOffset.height) / 300.0)))
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedMedia = nil
                        dragOffset = .zero
                    }
                }

            VStack {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button(action: {
                            PlatformClipboard.copy(item.shareURL(with: configService).absoluteString)
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 16, weight: .semibold))
                                .padding(10)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        #if os(iOS)
                        if item.type == .image || item.type == .video {
                            Button(action: {
                                saveMediaToPhotos(item: item)
                            }) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 16, weight: .semibold))
                                    .padding(10)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                        #endif

                        SourceIndicatorView(url: item.url)

                        Spacer()

                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedMedia = nil
                                dragOffset = .zero
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                    #if os(iOS)
                    if let message = saveToPhotosMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(message.contains("Saved") ? .green : .red)
                            .transition(.opacity)
                    }
                    #endif
                }
                .padding()
                .opacity(max(0, 1.0 - (abs(dragOffset.height) / 100.0)))

                Spacer()

                TabView(selection: $selectedMedia) {
                    ForEach(displayMedia) { mediaItem in
                        ViewerViewMediaItem(mediaItem: mediaItem)
                            .tag(mediaItem as MediaItem?)
                    }
                }
                .mediaTabViewStyleCompat()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: dragOffset.height)
                .scaleEffect(max(0.8, 1.0 - (abs(dragOffset.height) / 1000.0)))
                .gesture(
                    DragGesture()
                        .onChanged { gesture in
                            if abs(gesture.translation.height) > abs(gesture.translation.width) || dragOffset.height != 0 {
                                dragOffset = CGSize(width: 0, height: gesture.translation.height)
                            }
                        }
                        .onEnded { gesture in
                            if abs(dragOffset.height) > 120 {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    selectedMedia = nil
                                    dragOffset = .zero
                                }
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                    dragOffset = .zero
                                }
                            }
                        }
                )

                Spacer()

                Text(item.shareURL(with: configService).absoluteString)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .padding(.bottom)
                    .opacity(max(0, 1.0 - (abs(dragOffset.height) / 100.0)))
            }
        }
        .transition(.opacity)
        #if os(iOS)
        .background(ClearFullScreenBackground())
        #endif
    }

    @ViewBuilder
    private var fullScreenOverlay: some View {
        #if os(macOS)
        if let item = selectedMedia {
            mediaViewerContent(for: item)
        }
        #endif
    }

    #if os(iOS)
    private func saveMediaToPhotos(item: MediaItem) {
        saveToPhotosMessage = nil

        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await MainActor.run {
                    saveToPhotosMessage = "Photo library access denied"
                }
                return
            }

            let session = URLSession(configuration: .default, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
            do {
                let (data, _) = try await session.data(from: item.url)

                if item.type == .video {
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                    try data.write(to: tempURL)
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: tempURL, options: nil)
                    }
                    try? FileManager.default.removeItem(at: tempURL)
                } else {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        request.addResource(with: .photo, data: data, options: options)
                    }
                }

                await MainActor.run {
                    withAnimation { saveToPhotosMessage = "Saved to Photos" }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await MainActor.run { withAnimation { saveToPhotosMessage = nil } }
                    }
                }
            } catch {
                await MainActor.run {
                    saveToPhotosMessage = "Failed to save media"
                }
            }
        }
    }
    #endif

    #if os(macOS)
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard selectedMedia != nil else { return event }
            switch event.keyCode {
            case 123: // left arrow
                navigateMedia(direction: -1)
                return nil
            case 124: // right arrow
                navigateMedia(direction: 1)
                return nil
            case 53: // escape
                withAnimation(.easeInOut(duration: 0.2)) { selectedMedia = nil }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    #endif

    private func navigateMedia(direction: Int) {
        guard let current = selectedMedia,
              let index = displayMedia.firstIndex(where: { $0.id == current.id }) else { return }
        let newIndex = index + direction
        guard displayMedia.indices.contains(newIndex) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { selectedMedia = displayMedia[newIndex] }
    }

    private var sectionEmptyIcon: String {
        switch selectedSection {
        case .notes: return "text.bubble"
        case .media: return "photo"
        case .replies: return "arrowshape.turn.up.left"
        }
    }

    // MARK: - Refresh

    private func refreshProfile() async {
        nostrService.fetchMissingProfiles(for: [pubkey])

        disconnectClients()
        profileNotes.removeAll()
        seenNoteIds.removeAll()
        isLoadingNotes = false
        followingCount = nil
        followsMe = false
        followersCount = nil
        followerPubkeys.removeAll()

        fetchAuthorNotes()
        deriveBitcoinAddress()
        deriveSilentPaymentAddress()
        fetchLightningBalance()

        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    // MARK: - Lightning balance (own profile)

    private func fetchLightningBalance() {
        guard isOwnerProfile, !ConfigService.shared.config.nwcURI.isEmpty else { return }
        guard !isLoadingLightningBalance else { return }
        isLoadingLightningBalance = true
        Task {
            do {
                let msats = try await NWCService.getBalance()
                let sats = msats / 1000
                await MainActor.run {
                    lightningBalanceSats = sats
                    isLoadingLightningBalance = false
                }
            } catch {
                await MainActor.run {
                    isLoadingLightningBalance = false
                }
                #if DEBUG
                print("ProfileView: lightning balance fetch failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Profile editing

    private func applyProfileUpdate(_ updated: FeedProfile) {
        nostrService.profiles[pubkey] = updated
    }

    // MARK: - Note streaming

    private func fetchAuthorNotes() {
        guard !isLoadingNotes else { return }
        isLoadingNotes = true

        let existing = feedService.notes.filter { $0.pubkey == pubkey }
        for note in existing {
            if !seenNoteIds.contains(note.id) {
                seenNoteIds.insert(note.id)
                profileNotes.append(note)
            }
        }
        profileNotes.sort { $0.createdAt > $1.createdAt }

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
        // Cap at 1 external relay to avoid multiplying data fetches across all relays.
        relayURLs.append(contentsOf: externalStrs.prefix(1).compactMap { URL(string: $0) })

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
                        let notesFilter: [String: Any] = [
                            "kinds": [1, 6, 30023],
                            "authors": [pubkey],
                            "limit": 50
                        ]
                        let contactFilter: [String: Any] = [
                            "kinds": [3],
                            "authors": [pubkey],
                            "limit": 1
                        ]
                        let followersFilter: [String: Any] = [
                            "kinds": [3],
                            "#p": [pubkey],
                            "limit": 100
                        ]
                        let req: [Any] = ["REQ", "profile-\(UUID().uuidString.prefix(6))", notesFilter, contactFilter, followersFilter]
                        if let data = try? JSONSerialization.data(withJSONObject: req),
                           let str = String(data: data, encoding: .utf8) {
                            client.send(text: str)
                        }
                    }
                }
                .store(in: &profileCancellables)

            client.connect(url: url)
        }

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

            if event.kind == 3 {
                let pTags = event.tags.filter { $0.count >= 2 && $0[0] == "p" }
                if event.pubkey == pubkey {
                    // This user's own contact list → extract following count and followsMe.
                    // followsMe is true if they follow ANY of our accounts (owner or
                    // whitelisted) so the badge is consistent across account switches.
                    let count = pTags.filter { $0[1] != pubkey }.count
                    self.followingCount = count
                    let ourHexKeys: Set<String> = Set(configService.allAccountNpubs.compactMap { Bech32.decode($0)?.hexString })
                    if !ourHexKeys.isEmpty {
                        self.followsMe = pTags.contains { ourHexKeys.contains($0[1]) }
                    }
                } else {
                    // Someone else's contact list containing this pubkey → they follow this user
                    followerPubkeys.insert(event.pubkey)
                    followersCount = followerPubkeys.count
                }
                return
            }

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

            profileNotes.append(note)
            profileNotes.sort { $0.createdAt > $1.createdAt }

            // Trigger fetch of the original note for empty-content reposts
            if event.kind == 6 && event.content.isEmpty,
               let refId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                feedService.fetchMissingNote(id: refId)
            }

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

    // MARK: - Silent Payment

    private func deriveSilentPaymentAddress() {
        do {
            let spAddr = try SilentPaymentService.deriveAddress(hexPubkey: pubkey)
            silentPaymentAddress = spAddr
        } catch {
            silentPaymentAddress = nil
        }
    }

    // MARK: - Bitcoin

    private func deriveBitcoinAddress() {
        guard let cAddr = pubkey.withCString({ DeriveTaprootAddressC(UnsafeMutablePointer(mutating: $0)) }) else { return }
        let address = String(cString: cAddr)
        guard !address.isEmpty else { return }
        bitcoinAddress = address
        fetchBitcoinBalance(address: address)
    }

    private func fetchBitcoinBalance(address: String) {
        Task {
            guard let url = URL(string: "https://mempool.btcforplebs.com/api/address/\(address)") else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }

            struct Stats: Decodable {
                let funded_txo_sum: Int
                let spent_txo_sum: Int
            }
            struct AddressResponse: Decodable {
                let chain_stats: Stats
                let mempool_stats: Stats
            }

            guard let response = try? JSONDecoder().decode(AddressResponse.self, from: data) else { return }
            let confirmed = response.chain_stats.funded_txo_sum - response.chain_stats.spent_txo_sum
            let unconfirmed = response.mempool_stats.funded_txo_sum - response.mempool_stats.spent_txo_sum
            let total = confirmed + unconfirmed

            await MainActor.run {
                bitcoinBalance = total
            }
        }
    }

    private func formatSats(_ sats: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        let formatted = formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
        return "\(formatted) sats"
    }

    private func shortSats(_ sats: Int) -> String {
        if sats >= 1_000_000 {
            return String(format: "%.1fM", Double(sats) / 1_000_000)
        } else if sats >= 1_000 {
            return String(format: "%.1fk", Double(sats) / 1_000)
        }
        return "\(sats)"
    }

    private func shortInt(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        }
        return "\(n)"
    }

    // MARK: - Helpers

    private var shortPubkey: String {
        String(pubkey.prefix(8)) + "…" + String(pubkey.suffix(4))
    }

    private var formattedNpub: String {
        if let data = Bech32.hexToData(pubkey),
           let npub = Bech32.encode(hrp: "npub", data: data) {
            return String(npub.prefix(12)) + "…" + String(npub.suffix(8))
        }
        return "npub…" + String(pubkey.suffix(8))
    }

    private func formattedAddress(_ address: String) -> String {
        guard address.count > 16 else { return address }
        return String(address.prefix(10)) + "…" + String(address.suffix(8))
    }

    private var lightningAddress: String? {
        guard let profile = profile else { return nil }
        if let lud06 = profile.lud06, !lud06.isEmpty { return "lnurl:" + lud06 }
        if let lud16 = profile.lud16, !lud16.isEmpty { return lud16 }
        // NIP-05 resolves to /.well-known/nostr.json — a completely different endpoint
        // from the LUD-16 /.well-known/lnurlp/ path. Do NOT use NIP-05 as a lightning address.
        return nil
    }

    private func copyNpub() {
        if let data = Bech32.hexToData(pubkey),
           let npub = Bech32.encode(hrp: "npub", data: data) {
            copyToClipboard(npub)
            triggerCopied($copiedNpub)
        }
    }

    private func copyToClipboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    private func triggerCopied(_ flag: Binding<Bool>) {
        flag.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            flag.wrappedValue = false
        }
    }

    private func toggleFollow() {
        let name = profile?.bestName ?? shortPubkey
        if isFollowing {
            switch feedService.unfollowUser(pubkey) {
            case .success:
                FollowNotificationManager.shared.add(recipientName: name, kind: .unfollowed)
            case .failure(let err):
                FollowNotificationManager.shared.add(recipientName: name, kind: .failed(unfollowErrorMessage(err)))
            }
        } else {
            switch feedService.followUser(pubkey) {
            case .success:
                FollowNotificationManager.shared.add(recipientName: name, kind: .followed)
            case .failure(let err):
                FollowNotificationManager.shared.add(recipientName: name, kind: .failed(followErrorMessage(err)))
            }
        }
    }

    private func followErrorMessage(_ err: FeedService.FollowActionError) -> String {
        switch err {
        case .contactsNotLoaded: return "Contacts still loading"
        case .alreadyFollowing:  return "Already following"
        case .cannotUnfollowSelf: return "Follow failed"
        }
    }

    private func unfollowErrorMessage(_ err: FeedService.FollowActionError) -> String {
        switch err {
        case .contactsNotLoaded:  return "Contacts still loading"
        case .cannotUnfollowSelf: return "Can't unfollow yourself"
        case .alreadyFollowing:   return "Unfollow failed"
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

// MARK: - ProfileEditView

struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    var onDismiss: (() -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService

    let existing: FeedProfile
    let onSave: (FeedProfile) -> Void

    @State private var displayName: String = ""
    @State private var name: String = ""
    @State private var about: String = ""
    @State private var pictureURL: String = ""
    @State private var nip05: String = ""
    @State private var lud16: String = ""
    @State private var website: String = ""

    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        platformContainer {
            VStack(spacing: 0) {
                editHeader

                ScrollView {
                    VStack(spacing: 0) {
                        previewBlock

                        divider

                        fieldGroup(title: "IDENTITY") {
                            field(label: "Display Name", text: $displayName, placeholder: "Satoshi Nakamoto")
                            fieldDivider
                            field(label: "Username", text: $name, placeholder: "satoshi")
                            fieldDivider
                            field(label: "NIP-05", text: $nip05, placeholder: "you@domain.com", keyboardKind: .emailLike)
                        }

                        divider

                        fieldGroup(title: "BIO") {
                            multilineField(label: "About", text: $about, placeholder: "Tell people about yourself…")
                        }

                        divider

                        fieldGroup(title: "MEDIA") {
                            field(label: "Picture URL", text: $pictureURL, placeholder: "https://…", keyboardKind: .urlLike)
                            fieldDivider
                            field(label: "Website", text: $website, placeholder: "yourdomain.com", keyboardKind: .urlLike)
                        }

                        divider

                        fieldGroup(title: "LIGHTNING") {
                            field(label: "Address (lud16)", text: $lud16, placeholder: "you@walletofsatoshi.com", keyboardKind: .emailLike)
                        }

                        if let err = errorMessage {
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Spacer(minLength: 32)
                    }
                }
            }
        }
        .onAppear { loadFromExisting() }
    }

    @ViewBuilder
    private func platformContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(macOS)
        content()
            .frame(minWidth: 480, minHeight: 600)
            .background(Color.platformWindowBackground)
        #else
        content()
            .background(Color.platformWindowBackground.ignoresSafeArea())
        #endif
    }

    private var editHeader: some View {
        HStack {
            Button("Cancel") { performDismiss() }
                .foregroundColor(.secondary)

            Spacer()

            Text("Edit Profile")
                .font(.system(size: 15, weight: .semibold))

            Spacer()

            Button(action: save) {
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Color.havenPurple)
                } else {
                    Text("Save")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.havenPurple)
                }
            }
            .disabled(isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.platformControlBackground)
        .overlay(
            Rectangle()
                .fill(Color.platformSeparator.opacity(0.5))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var previewBlock: some View {
        HStack(spacing: 14) {
            AvatarView(url: URL(string: pictureURL), pubkey: existing.pubkey)
                .frame(width: 56, height: 56)
                .overlay(Circle().stroke(Color.havenPurple.opacity(0.35), lineWidth: 1.5))

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName.isEmpty ? (name.isEmpty ? "Unnamed" : name) : displayName)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if !nip05.isEmpty {
                    Text(nip05)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if !about.isEmpty {
                    Text(about)
                        .font(.system(size: 12))
                        .foregroundColor(.primary.opacity(0.75))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.platformSeparator.opacity(0.5))
            .frame(height: 0.5)
            .padding(.vertical, 8)
    }

    private var fieldDivider: some View {
        Rectangle()
            .fill(Color.platformSeparator.opacity(0.4))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func fieldGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.7)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            content()
        }
    }

    enum KeyboardKind { case `default`, urlLike, emailLike }

    @ViewBuilder
    private func field(label: String, text: Binding<String>, placeholder: String, keyboardKind: KeyboardKind = .default) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)

            TextField(placeholder, text: text)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .modifier(KeyboardModifier(kind: keyboardKind))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func multilineField(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.top, 8)
                        .padding(.leading, 6)
                }
                #if os(iOS)
                TextEditor(text: text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90)
                #else
                TextEditor(text: text)
                    .font(.system(size: 13))
                    .frame(minHeight: 90)
                #endif
            }
            .padding(6)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func loadFromExisting() {
        displayName = existing.displayName ?? ""
        name = existing.name ?? ""
        about = existing.about ?? ""
        pictureURL = existing.pictureURL?.absoluteString ?? ""
        nip05 = existing.nip05 ?? ""
        lud16 = existing.lud16 ?? ""
        website = existing.website ?? ""
    }

    private func save() {
        errorMessage = nil
        isSaving = true

        var content: [String: String] = [:]
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { content["name"] = name.trimmingCharacters(in: .whitespaces) }
        if !displayName.trimmingCharacters(in: .whitespaces).isEmpty { content["display_name"] = displayName.trimmingCharacters(in: .whitespaces) }
        if !about.trimmingCharacters(in: .whitespaces).isEmpty { content["about"] = about.trimmingCharacters(in: .whitespaces) }
        if !pictureURL.trimmingCharacters(in: .whitespaces).isEmpty { content["picture"] = pictureURL.trimmingCharacters(in: .whitespaces) }
        if !nip05.trimmingCharacters(in: .whitespaces).isEmpty { content["nip05"] = nip05.trimmingCharacters(in: .whitespaces) }
        if !lud16.trimmingCharacters(in: .whitespaces).isEmpty { content["lud16"] = lud16.trimmingCharacters(in: .whitespaces) }
        if !website.trimmingCharacters(in: .whitespaces).isEmpty { content["website"] = website.trimmingCharacters(in: .whitespaces) }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            errorMessage = "Could not encode profile."
            isSaving = false
            return
        }

        guard let signed = nostrService.signEvent(kind: 0, content: jsonStr, tags: []) else {
            errorMessage = "Could not sign event. Check that your key is available."
            isSaving = false
            return
        }

        nostrService.postEvent(signed)

        var updated = existing
        updated.name = content["name"]
        updated.displayName = content["display_name"]
        updated.about = content["about"]
        updated.pictureURL = (content["picture"]).flatMap { URL(string: $0) }
        updated.nip05 = content["nip05"]
        updated.lud16 = content["lud16"]
        updated.website = content["website"]

        onSave(updated)

        isSaving = false
        performDismiss()
    }

    private func performDismiss() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

private struct KeyboardModifier: ViewModifier {
    let kind: ProfileEditView.KeyboardKind

    func body(content: Content) -> some View {
        #if os(iOS)
        switch kind {
        case .urlLike:
            content
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled(true)
        case .emailLike:
            content
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled(true)
        case .default:
            content
        }
        #else
        content
        #endif
    }
}
