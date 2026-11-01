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

    /// The account pictures head the list on screen (Vault list, no search).
    var showsAccountRowOnTop: Bool {
        viewMode == .activity && !isSearchActive && !accountChips.isEmpty
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
        }
        withAnimation(Motion.toggle) {
            accountChip = VaultAccountChips.isDefault(chip, active: me) ? nil : chip
        }
        loadOtherAccountActivity()
    }

    /// A line was opened: its account's count empties.
    func openedAccountLine(_ line: VaultAccountLine) {
        guard line.account != followersOwnerHex.lowercased() else { return }
        AccountUnreadStore.shared.markVaultSeen(hex: line.account)
    }

    /// Back to the active account's own list (account switched, or removed).
    func resetAccountChip() {
        otherAccountLoadTask?.cancel()
        accountChip = nil
        otherAccountActivity = [:]
        otherAccountUnreadSince = [:]
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
    func loadOtherAccountActivity() {
        let me = followersOwnerHex.lowercased()
        let wanted = VaultAccountChips.accounts(for: currentAccountChip, accounts: vaultAccountHexes).filter { $0 != me }
        otherAccountLoadTask?.cancel()
        guard !wanted.isEmpty, relayManager.isRunning, !relayManager.isBooting else {
            // Still starting: the spinner holds, and the relay-up handler
            // (VaultView) reads again.
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
        let trusted = FeedService.shared.relayTabTrustedPubkeys()
        let mutes = MuteListStore.shared.active
        let noteKinds = NostrService.relayTabNoteKinds
        let service = nostrService
        // A spinner while any picked account has nothing read yet, not only
        // the first one picked.
        otherAccountLoading = wanted.contains { otherAccountActivity[$0] == nil }
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
                        async let mine = service.fetchEvents(
                            filter: ["authors": [hex], "kinds": noteKinds, "limit": limit],
                            from: [base], includeLoopback: true)
                        async let tagged = service.fetchEvents(
                            filter: ["#p": [hex], "kinds": noteKinds + [16], "limit": limit],
                            from: [base + "/inbox"], includeLoopback: true)
                        async let reactions = service.fetchEvents(
                            filter: ["#p": [hex], "kinds": [7, 9735], "limit": limit],
                            from: [base + "/inbox"], includeLoopback: true)
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
                            isOutside: { ContentFilter.isOutside(author: $0, owner: hex, whitelist: whitelist, trusted: trusted) }
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
            for (hex, lines) in built { otherAccountActivity[hex] = lines }
            otherAccountReadFull = readFull
            otherAccountLoading = false
            service.fetchMissingProfiles(for: Array(Set(built.values.flatMap { $0.flatMap { $0.actors.prefix(5) } })))
        }
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
                        isSelected: chip == currentAccountChip,
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
