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
    }

    /// Reads the picked chip's other accounts from the device's relay and
    /// builds their lines with the same rules as the active account's.
    func loadOtherAccountActivity() {
        let me = followersOwnerHex.lowercased()
        let wanted = VaultAccountChips.accounts(for: currentAccountChip, accounts: vaultAccountHexes).filter { $0 != me }
        otherAccountLoadTask?.cancel()
        guard !wanted.isEmpty, relayManager.isRunning else {
            otherAccountLoading = false
            return
        }
        let base = configService.config.nostrURL
        let npubs = Dictionary(configService.allAccountNpubs.compactMap { npub in
            Bech32.decode(npub).map { ($0.hexString.lowercased(), npub) }
        }, uniquingKeysWith: { a, _ in a })
        let blocked = Dictionary(wanted.map { ($0, configService.blockedHexPubkeys(forAccount: npubs[$0] ?? "")) },
                                 uniquingKeysWith: { a, _ in a })
        let whitelist = configService.whitelistedHexPubkeys
        let trusted = FeedService.shared.relayTabTrustedPubkeys()
        let mutes = MuteListStore.shared.active
        let noteKinds = NostrService.relayTabNoteKinds
        let service = nostrService
        otherAccountLoading = otherAccountActivity.isEmpty
        otherAccountLoadTask = Task { @MainActor in
            var built: [String: [VaultActivity]] = [:]
            await withTaskGroup(of: (String, [VaultActivity]).self) { group in
                for hex in wanted {
                    group.addTask {
                        async let mine = service.fetchEvents(
                            filter: ["authors": [hex], "kinds": noteKinds, "limit": 300],
                            from: [base], includeLoopback: true)
                        async let tagged = service.fetchEvents(
                            filter: ["#p": [hex], "kinds": noteKinds + [16], "limit": 300],
                            from: [base + "/inbox"], includeLoopback: true)
                        async let reactions = service.fetchEvents(
                            filter: ["#p": [hex], "kinds": [7, 9735], "limit": 300],
                            from: [base + "/inbox"], includeLoopback: true)
                        let events = await mine + tagged + reactions
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
                            isBlocked: { block.contains($0) },
                            isOutside: { ContentFilter.isOutside(author: $0, owner: hex, whitelist: whitelist, trusted: trusted) }
                        )
                        return (hex, lines)
                    }
                }
                for await (hex, lines) in group { built[hex] = lines }
            }
            guard !Task.isCancelled else { return }
            for (hex, lines) in built { otherAccountActivity[hex] = lines }
            otherAccountLoading = false
            service.fetchMissingProfiles(for: Array(Set(built.values.flatMap { $0.flatMap { $0.actors.prefix(5) } })))
        }
    }

    // MARK: Chips

    /// "All · <acct> · <acct>": the active account first after All, each
    /// other account with its new-notification count from the switcher.
    var accountChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
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
            .padding(.vertical, 2)
        }
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
            HStack(spacing: 6) {
                if let hex {
                    AvatarView(url: nostrService.profiles[hex]?.pictureURL, pubkey: hex, size: 20)
                }
                Text(title)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let badge {
                    Text(badge)
                        .font(.appSystem(size: 10, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(isSelected ? Color.havenPurple : .white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(isSelected ? Color.white : Color.havenPurple))
                }
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.leading, hex == nil ? 14 : 5)
            .padding(.trailing, 12)
            .frame(minHeight: 32)
            .background(Capsule().fill(isSelected ? Color.havenPurple : Color.havenPurple.opacity(0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge.map { "\(title), \($0) new" } ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
