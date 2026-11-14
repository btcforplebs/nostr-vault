import SwiftUI

// MARK: - Every account's notifications

/// The Vault list for more than one account: "All · <acct> · <acct>" chips
/// over it, each line marked with the account it is for. The device's relay
/// serves every account, so another account's lines are read from it the
/// same way the active account's are. With one account none of this shows.
/// Android: VaultAccountChipRow.kt (AccountChipRow).
extension VaultView {

    /// Every account on the device, by hex, in switcher order.
    var vaultAccountHexes: [String] {
        configService.allAccountNpubs.compactMap { Bech32.decode($0)?.hexString.lowercased() }
    }

    var accountChips: [VaultAccountChip] {
        VaultAccountChips.chips(accounts: vaultAccountHexes, active: followersOwnerHex)
    }

    var currentAccountChip: VaultAccountChip {
        VaultAccountChips.resolve(accountChip, accounts: vaultAccountHexes, active: followersOwnerHex)
    }

    /// The account pictures head the list on screen (no search; every page
    /// but Media).
    var showsAccountRowOnTop: Bool {
        !isSearchActive && !accountChips.isEmpty && VaultAccountChips.pageShowsChips(viewMode.accountPage)
    }

    /// The accounts the chip shows (lowercased hex): the active one alone
    /// unless another chip is picked.
    var pageOwners: Set<String> {
        Set(VaultAccountChips.accounts(for: currentAccountChip, accounts: vaultAccountHexes))
    }

    /// True when the list is anything but the active account's own.
    var showsOtherAccounts: Bool {
        !VaultAccountChips.isDefault(currentAccountChip, active: followersOwnerHex)
    }

    /// The lines for the picked chip: the active account's as already built,
    /// the others' filtered the same way, interleaved newest first.
    var accountLines: [VaultAccountLine] {
        let me = followersOwnerHex.lowercased()
        let zapsOnly = configService.config.zapsOnlyMode
        var perAccount: [String: [VaultActivity]] = [:]
        for hex in VaultAccountChips.accounts(for: currentAccountChip, accounts: vaultAccountHexes) {
            if hex == me {
                perAccount[hex] = displayActivity
            } else if activityFilter == .outside {
                // Outside your web is built for the active account only.
                perAccount[hex] = []
            } else {
                perAccount[hex] = (otherAccountActivity[hex] ?? [])
                    .filter { activityFilter.includes($0.kind) && !(zapsOnly && $0.kind == .reaction) }
            }
        }
        return VaultAccountChips.merge(perAccount, order: vaultAccountHexes, limit: maxDisplayedItems)
    }

    func accountUnreadSince(_ hex: String) -> Int64 {
        hex == followersOwnerHex.lowercased() ? activityUnreadSince : (otherAccountUnreadSince[hex] ?? .max)
    }

    /// A chip was picked: each other account it shows counts as viewed, the
    /// way opening that account's Vault list would, then its lines load.
    func pickAccountChip(_ chip: VaultAccountChip) {
        let me = followersOwnerHex.lowercased()
        let now = Date().timeIntervalSince1970
        for hex in VaultAccountChips.accounts(for: chip, accounts: vaultAccountHexes) where hex != me {
            let last = AccountUnreadStore.shared.markVaultSeen(hex: hex, at: now)
            // A first visit marks nothing: everything would be "new".
            otherAccountUnreadSince[hex] = Int64(last > 0 ? last : now)
            otherAccountSeenCounts[hex] = 0
        }
        let onActivity = viewMode == .activity
        let loaded = Set(onActivity ? Array(otherAccountActivity.keys) : Array(otherAccountEvents.keys))
        if VaultAccountChips.needsRead(chip, accounts: vaultAccountHexes, active: me, loaded: loaded) {
            // Keep the list on screen; switch when this chip's lines are read.
            pendingAccountChip = chip
            if onActivity {
                loadOtherAccountActivity(for: chip, then: { applyAccountChip(chip) })
            } else {
                loadOtherAccountPages(for: chip, then: { applyAccountChip(chip) })
            }
        } else {
            // Its lines are held: show them. No read here; a new badge, the
            // relay coming up or a refresh tops them up (Logen 2026-11-14:
            // the tap itself triggers no reload).
            applyAccountChip(chip)
        }
    }

    /// The page changed: read what the new page needs that isn't held yet
    /// (with another chip picked, the list stays until it lands).
    func vaultPageChanged() {
        guard hasOtherAccounts else { return }
        if viewMode == .activity {
            if VaultAccountChips.needsRead(.all, accounts: vaultAccountHexes,
                                           active: followersOwnerHex, loaded: Set(otherAccountActivity.keys)) {
                loadOtherAccountActivity()
            }
        } else if viewMode != .media {
            loadOtherAccountPages()
        }
    }

    /// A block or mute changed: the other accounts are read anew (not
    /// topped up), so lines that now hide go.
    func rereadOtherAccounts() {
        readOtherAccountsAhead(replacing: true)
    }

    /// More than one account on the device: the chips show.
    var hasOtherAccounts: Bool {
        !VaultAccountChips.otherAccounts(vaultAccountHexes, active: followersOwnerHex).isEmpty
    }

    /// Reads every other account's lines before any chip is tapped (the
    /// Vault opens, the relay comes up, the active account changes, news
    /// comes in), so a tap only shows what is held: no read, no wait, no
    /// freeze (Logen 2026-11-14). The Vault list's lines always; a page's
    /// events when that page is open. A pick still waiting is read by its
    /// own read.
    func readOtherAccountsAhead(replacing: Bool = false) {
        guard hasOtherAccounts else { return }
        loadOtherAccountActivity(replacing: replacing)
        if viewMode != .activity && viewMode != .media {
            loadOtherAccountPages(replacing: replacing)
        }
    }

    /// Whether `state` has news for any account besides the active one (all
    /// are held, shown or not): a count above the one it had when last read
    /// or tapped. The counts are taken as the new baseline either way.
    func shownAccountsGotNews(_ state: AccountUnread) -> Bool {
        let shown = VaultAccountChips.otherAccounts(vaultAccountHexes, active: followersOwnerHex)
        guard !shown.isEmpty else { return false }
        let before = otherAccountSeenCounts
        for hex in shown { otherAccountSeenCounts[hex] = state.count(for: hex) }
        return VaultAccountChips.countRose(among: shown, before: { before[$0] ?? 0 }, after: { state.count(for: $0) })
    }

    /// The list switches to `chip` (its lines are read, or are being topped up).
    func applyAccountChip(_ chip: VaultAccountChip) {
        pendingAccountChip = nil
        withAnimation(Motion.toggle) {
            accountChip = VaultAccountChips.isDefault(chip, active: followersOwnerHex) ? nil : chip
        }
        // The pages build from the picked accounts' events.
        if viewMode != .activity { scheduleUpdateDisplayData() }
    }

    /// A line was opened: the counts of every account it is for empty.
    func openedAccountLine(_ line: VaultAccountLine) {
        let me = followersOwnerHex.lowercased()
        for hex in line.accounts where hex != me {
            AccountUnreadStore.shared.markVaultSeen(hex: hex)
        }
    }

    /// Back to the active account's own list (account switched, or removed).
    func resetAccountChip() {
        otherAccountLoadTask?.cancel()
        otherPageLoadTask?.cancel()
        accountChip = nil
        pendingAccountChip = nil
        otherAccountActivity = [:]
        otherAccountEvents = [:]
        otherFollowerSnapshots = [:]
        pageNoteAccount = [:]
        otherAccountUnreadSince = [:]
        otherAccountSeenCounts = [:]
        otherAccountLoading = false
        otherAccountLimit = VaultAccountChips.otherAccountPage
        otherAccountReadFull = false
    }

    /// The active account changed (a line for another account was opened,
    /// or the switcher). The account left is marked seen now, so what came in
    /// while its list was open doesn't bring its badge back. The new one's
    /// dots start from the mark its chip used, or from a fresh visit when its
    /// list is on screen. Android: VaultActivityViewModel's accountSwitches.
    func activeAccountChanged(from old: String, to new: String) {
        let left = old.lowercased(), now = Date().timeIntervalSince1970
        let carried = otherAccountUnreadSince[new.lowercased()]
        if !left.isEmpty, viewMode == .activity { AccountUnreadStore.shared.markVaultSeen(hex: left, at: now) }
        resetAccountChip()
        if let carried {
            activityUnreadSince = carried
        } else if viewMode == .activity {
            activityVisit(arriving: true)
        } else {
            activityUnreadSince = .max
        }
        // The new active account's others are read again, ahead of a tap.
        readOtherAccountsAhead()
    }

    /// "Load more" with other accounts' lines on screen: show more of what
    /// is read, then read further back, theirs and (with All) the active
    /// account's.
    func loadMoreAccountLines() {
        if accountLines.count >= maxDisplayedItems {
            maxDisplayedItems += 50
            scheduleUpdateDisplayData()
            return
        }
        if let next = VaultAccountChips.nextOtherAccountLimit(current: otherAccountLimit, readFull: otherAccountReadFull) {
            otherAccountLimit = next
            loadOtherAccountActivity()
        }
        let me = followersOwnerHex.lowercased()
        if VaultAccountChips.accounts(for: currentAccountChip, accounts: vaultAccountHexes).contains(me),
           !nostrService.isFetching {
            loadMore()
        }
    }

    /// Reads the picked chip's other accounts from the device's relay and
    /// builds their lines with the same rules as the active account's.
    /// `chip` is a pick still waiting for its read (the list on screen
    /// stays, so no spinner); `then` runs once that read is in, and the first
    /// screen's profiles are in or `profileWait` passed. The read tops up what
    /// is held (`topUp`) unless `replacing`: a rule changed and lines must go.
    func loadOtherAccountActivity(for chip: VaultAccountChip? = nil, replacing: Bool = false,
                                  then: (() -> Void)? = nil) {
        // A re-read (relay up, a notification) while a pick waits: it reads
        // for that pick and still switches to it, rather than leaving it stuck.
        if chip == nil, let waiting = pendingAccountChip {
            loadOtherAccountActivity(for: waiting, replacing: replacing, then: { applyAccountChip(waiting) })
            return
        }
        let me = followersOwnerHex.lowercased()
        // Every other account, whichever chip: each read holds all of their
        // lines, so any later tap only shows them (Logen 2026-11-14).
        let wanted = VaultAccountChips.otherAccounts(vaultAccountHexes, active: me)
        let pending = chip != nil
        otherAccountLoadTask?.cancel()
        guard !wanted.isEmpty, relayManager.isRunning, !relayManager.isBooting else {
            // Still starting: the spinner holds, and the relay-up handler
            // (VaultView) reads again. A waiting pick switches now: there is
            // nothing to read yet, and the list it leaves is the same story.
            if let then { then() }
            otherAccountLoading = !wanted.isEmpty && relayManager.isBooting
            return
        }
        let base = configService.config.nostrURL
        let npubs = Dictionary(configService.allAccountNpubs.compactMap { npub in
            Bech32.decode(npub).map { ($0.hexString.lowercased(), npub) }
        }, uniquingKeysWith: { a, _ in a })
        let blocked = Dictionary(wanted.map { ($0, configService.blockedHexPubkeys(forAccount: npubs[$0] ?? "")) },
                                 uniquingKeysWith: { a, _ in a })
        let whitelist = configService.whitelistedHexPubkeys
        let ownAccounts = configService.allAccountHexes
        let notifyOwn = configService.config.notifyOwnAccountTags
        // Each account's own web, not the open account's.
        let webs = Dictionary(wanted.map { ($0, FeedService.shared.trustedPubkeys(for: $0)) },
                              uniquingKeysWith: { a, _ in a })
        let mutes = MuteListStore.shared.active
        let noteKinds = NostrService.relayTabNoteKinds
        let service = nostrService
        // A spinner while any picked account has nothing read yet, not only
        // the first one picked.
        otherAccountLoading = !pending && wanted.contains { otherAccountActivity[$0] == nil }
        let limit = otherAccountLimit
        // Cleared while the read is in flight, so "load more" can't raise
        // the limit again before this one answers.
        otherAccountReadFull = false
        otherAccountLoadTask = Task { @MainActor in
            var built: [String: [VaultActivity]] = [:]
            var readFull = false
            await withTaskGroup(of: (String, [VaultActivity], Bool).self) { group in
                for hex in wanted {
                    group.addTask {
                        async let mine = service.vaultAccountEvents(
                            filter: ["authors": [hex], "kinds": noteKinds, "limit": limit],
                            from: [base])
                        async let tagged = service.vaultAccountEvents(
                            filter: ["#p": [hex], "kinds": noteKinds + [16], "limit": limit],
                            from: [base + "/inbox"])
                        async let reactions = service.vaultAccountEvents(
                            filter: ["#p": [hex], "kinds": [7, 9735], "limit": limit],
                            from: [base + "/inbox"])
                        let reads = await [mine, tagged, reactions]
                        let full = reads.contains { $0.count >= limit }
                        let events = reads.flatMap { $0 }
                        let follows = FollowerSnapshot.load(owner: hex)?.current
                            .filter(\.isNews).map { (pubkey: $0.pubkey, at: $0.followedAt) } ?? []
                        let block = blocked[hex] ?? []
                        let lines = VaultActivity.build(
                            events: events.filter { $0.pubkey == hex || !mutes.hides(id: $0.id, content: $0.content, tags: $0.tags) }.map {
                                VaultActivity.Event(id: $0.id, pubkey: $0.pubkey, kind: $0.kind,
                                                    createdAt: $0.created_at, content: $0.content, tags: $0.tags,
                                                    images: $0.mediaURLs.filter(\.isImage))
                            },
                            owner: hex,
                            noteKinds: Set(noteKinds),
                            follows: follows,
                            isBlocked: {
                                block.contains($0) || NotificationPolicy.hidesOwnAccountTag(
                                    author: $0, recipient: hex, accounts: ownAccounts, notify: notifyOwn)
                            },
                            isOutside: { ContentFilter.isOutside(author: $0, owner: hex, whitelist: whitelist, trusted: webs[hex] ?? []) },
                            foldsOutsideLikes: true
                        )
                        return (hex, lines, full)
                    }
                }
                for await (hex, lines, full) in group {
                    built[hex] = lines
                    if full { readFull = true }
                }
            }
            guard !Task.isCancelled else { return }
            service.fetchMissingProfiles(for: Array(Set(built.values.flatMap { $0.flatMap { $0.actors.prefix(5) } })))
            if then != nil {
                // The list on screen stays while the picked one's first
                // names come in, so its rows don't change under the eye.
                let first = VaultAccountChips.firstScreenActors(
                    VaultAccountChips.merge(built, order: vaultAccountHexes, limit: VaultAccountChips.firstScreenRows).map(\.line))
                await Self.awaitProfiles(first, service: service)
                guard !Task.isCancelled else { return }
            }
            for (hex, lines) in built {
                otherAccountActivity[hex] = replacing ? lines : VaultAccountChips.topUp(
                    held: otherAccountActivity[hex] ?? [], read: lines, id: \.id, at: \.createdAt)
            }
            otherAccountReadFull = readFull
            otherAccountLoading = false
            then?()
        }
    }

    /// Waits until `pubkeys` all have a profile, or `profileWait` passes.
    static func awaitProfiles(_ pubkeys: [String], service: NostrService) async {
        guard pubkeys.contains(where: { service.profiles[$0] == nil }) else { return }
        _ = await NotificationReadiness.wait(timeout: VaultAccountChips.profileWait, interval: 0.05) {
            await MainActor.run { pubkeys.allSatisfy { service.profiles[$0] != nil } }
        }
    }

    // MARK: Pages

    /// Reads, for the chip's other accounts, what Notes, Likes and Zaps build
    /// from (their posts and likes, what tags them, likes and zaps on them,
    /// zaps they sent, and the posts they liked or zapped) and their
    /// followers ledger. `chip` is a pick still waiting for this read (the
    /// list on screen stays); `then` runs once it is in and the first rows'
    /// profiles are in or `profileWait` passed. The read tops up what is held.
    func loadOtherAccountPages(for chip: VaultAccountChip? = nil, replacing: Bool = false,
                               then: (() -> Void)? = nil) {
        if chip == nil, let waiting = pendingAccountChip {
            loadOtherAccountPages(for: waiting, replacing: replacing, then: { applyAccountChip(waiting) })
            return
        }
        let me = followersOwnerHex.lowercased()
        // Every other account, whichever chip: each read holds all of their
        // lines, so any later tap only shows them (Logen 2026-11-14).
        let wanted = VaultAccountChips.otherAccounts(vaultAccountHexes, active: me)
        otherPageLoadTask?.cancel()
        guard !wanted.isEmpty, relayManager.isRunning, !relayManager.isBooting else {
            then?()
            return
        }
        let base = configService.config.nostrURL
        let npubs = vaultAccountNpubsByHex
        let blocked = Dictionary(wanted.map { ($0, configService.blockedHexPubkeys(forAccount: npubs[$0] ?? "")) },
                                 uniquingKeysWith: { a, _ in a })
        let noteKinds = NostrService.relayTabNoteKinds
        let limit = VaultAccountChips.otherAccountPage
        let service = nostrService
        otherPageLoadTask = Task { @MainActor in
            var built: [String: [NostrEvent]] = [:]
            var ledgers: [String: FollowerSnapshot] = [:]
            await withTaskGroup(of: (String, [NostrEvent], FollowerSnapshot?).self) { group in
                for hex in wanted {
                    group.addTask {
                        async let mine = service.vaultAccountEvents(
                            filter: ["authors": [hex], "kinds": noteKinds + [7], "limit": limit],
                            from: [base])
                        async let tagged = service.vaultAccountEvents(
                            filter: ["#p": [hex], "kinds": noteKinds + [6, 7, 9735], "limit": limit],
                            from: [base + "/inbox"])
                        async let sent = service.vaultAccountEvents(
                            filter: ["#P": [hex], "kinds": [9735], "limit": limit],
                            from: [base, base + "/inbox"])
                        let first = await [mine, tagged, sent].flatMap { $0 }
                        // The posts they liked or zapped, for My Likes / My Zaps.
                        let have = Set(first.map(\.id))
                        let wantIds = VaultAccountChips.givenTargets(
                            first.map { ($0.pubkey, $0.kind, $0.tags) }, account: hex).filter { !have.contains($0) }
                        let targets = wantIds.isEmpty ? [] : await service.vaultAccountEvents(
                            filter: ["ids": Array(wantIds.prefix(limit))], from: [base, base + "/inbox"])
                        let block = blocked[hex] ?? []
                        var seen = Set<String>()
                        let events = (first + targets).filter {
                            ($0.pubkey.lowercased() == hex || !block.contains($0.pubkey)) && seen.insert($0.id).inserted
                        }
                        return (hex, events, FollowerSnapshot.load(owner: hex))
                    }
                }
                for await (hex, events, ledger) in group {
                    built[hex] = events
                    if let ledger { ledgers[hex] = ledger }
                }
            }
            guard !Task.isCancelled else { return }
            service.fetchMissingProfiles(for: Array(Set(built.values.flatMap { $0.prefix(100).map(\.pubkey) })))
            if then != nil {
                let newest = built.values.joined().sorted { $0.created_at > $1.created_at }
                    .prefix(VaultAccountChips.firstScreenRows)
                var seen = Set<String>()
                await Self.awaitProfiles(newest.map(\.pubkey).filter { seen.insert($0).inserted }, service: service)
                guard !Task.isCancelled else { return }
            }
            for (hex, events) in built {
                otherAccountEvents[hex] = replacing ? events : VaultAccountChips.topUp(
                    held: otherAccountEvents[hex] ?? [], read: events, id: \.id, at: \.created_at)
            }
            for (hex, ledger) in ledgers { otherFollowerSnapshots[hex] = ledger }
            // Read ahead with the active account's own list on screen:
            // nothing to rebuild until a chip shows them.
            if showsOtherAccounts || then != nil {
                then?()
                scheduleUpdateDisplayData()
            }
        }
    }

    /// A page row: opens the post; another account's post switches to that
    /// account first, so a reply or like from it signs with the right key.
    @ViewBuilder
    func pageNoteLink<Row: View>(_ event: NostrEvent, @ViewBuilder row: () -> Row) -> some View {
        let content = row()
        #if os(iOS)
        if let account = pageNoteAccount[event.id] {
            Button { openPageNote(event.id, account: account) } label: { content }
                .buttonStyle(.plain)
        } else {
            content
            .contentShape(Rectangle())
            // A tap, not a Button: the row's own Buttons would die inside one
            // (NoteNavigationLink.swift). Not a NavigationLink: every Vault
            // row opens through openNote, one push path.
            .onTapGesture {
                openNote(FeedNote(id: event.id, pubkey: event.pubkey, content: event.content,
                                  createdAt: event.createdAtDate, tags: event.tags, kind: event.kind))
            }
            .accessibilityAddTraits(.isButton)
        }
        #else
        content
            .contentShape(Rectangle())
            .onTapGesture { openPageNote(event.id, account: pageNoteAccount[event.id]) }
        #endif
    }

    func openPageNote(_ id: String, account: String?) {
        if let npub = VaultAccountChips.switchTarget(lineAccount: account, active: followersOwnerHex,
                                                     npubByHex: vaultAccountNpubsByHex) {
            configService.switchActiveAccount(to: npub)
            if let account { AccountSwitchFlash.shared.show(hex: account) }
        }
        openNote(id)
    }

    // MARK: Chips

    /// "All · <acct> · <acct>": the active account first after All, each
    /// other account with its new-notification count from the switcher.
    var accountChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(accountChips, id: \.self) { chip in
                    VaultAccountChipView(
                        chip: chip,
                        // A pick still reading shows its ring at once.
                        isSelected: chip == (pendingAccountChip ?? currentAccountChip),
                        isActiveAccount: chip == .account(followersOwnerHex.lowercased()),
                        npub: chipNpub(chip)
                    ) { pickAccountChip(chip) }
                }
            }
            .padding(.horizontal, 16)
            // Room for the ring and the red bubble's overhang.
            .padding(.vertical, 6)
        }
    }

    /// Each account on the device, hex (lowercased) to npub.
    var vaultAccountNpubsByHex: [String: String] {
        Dictionary(configService.allAccountNpubs.compactMap { npub in
            Bech32.decode(npub).map { ($0.hexString.lowercased(), npub) }
        }, uniquingKeysWith: { a, _ in a })
    }

    private func chipNpub(_ chip: VaultAccountChip) -> String? {
        guard case .account(let hex) = chip else { return nil }
        return configService.allAccountNpubs.first { Bech32.decode($0)?.hexString.lowercased() == hex }
    }
}

/// One chip: the account's picture and name (or "All"), and its count.
struct VaultAccountChipView: View {
    let chip: VaultAccountChip
    let isSelected: Bool
    let isActiveAccount: Bool
    let npub: String?
    let action: () -> Void
    @EnvironmentObject var nostrService: NostrService
    @ObservedObject private var unreadStore = AccountUnreadStore.shared

    private var hex: String? {
        if case .account(let hex) = chip { return hex }
        return nil
    }

    private var title: String {
        guard let hex else { return "All" }
        return nostrService.profiles[hex]?.bestName ?? npub.map(AccountSwitcherIdentity.shortNpub) ?? "npub…" + String(hex.suffix(6))
    }

    /// The active account's count lives on the Vault tab's own dot.
    private var badge: String? {
        guard let hex, !isActiveAccount else { return nil }
        return AccountUnread.badge(unreadStore.state.count(for: hex))
    }

    var body: some View {
        Button(action: action) {
            if let hex {
                // The picture alone, larger: the name is in its label. The
                // ring marks the picked one, a red bubble that it has news.
                AvatarView(url: nostrService.profiles[hex]?.pictureURL, pubkey: hex, size: Self.pictureSize)
                    .padding(3)
                    .overlay(Circle().stroke(isSelected ? Color.havenPurple : Color.clear, lineWidth: 2.5))
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Text(badge)
                                .font(.appSystem(size: 11, weight: .bold))
                                .monospacedDigit()
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 20, minHeight: 20)
                                .background(Capsule().fill(Color.red))
                                .overlay(Capsule().stroke(Color.platformWindowBackground, lineWidth: 2))
                                .offset(x: 6, y: -4)
                        }
                    }
                    .contentShape(Circle())
            } else {
                Text(title)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(isSelected ? .white : .primary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: Self.pictureSize + 6)
                    .background(Capsule().fill(isSelected ? Color.havenPurple : Color.havenPurple.opacity(0.10)))
                    .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge.map { "\(title), \($0) new" } ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    static let pictureSize: CGFloat = 40
}
