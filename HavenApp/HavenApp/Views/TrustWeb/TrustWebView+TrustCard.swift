import SwiftUI

extension TrustWebView {
    // MARK: - Trust card

    func openCard(_ pubkey: String) {
        withAnimation(Motion.fade) {
            card = pubkey
            cardPath = nil
        }
        nostrService.fetchMissingProfiles(for: [pubkey])
        Task {
            // From you, whoever is in the middle: which of your follows follow them.
            let found = await TrustPathService.shared.path(for: pubkey)
            guard card == pubkey else { return }
            nostrService.fetchMissingProfiles(for: found.bridges)
            withAnimation(Motion.fade) { cardPath = found }
        }
    }

    func closeCard() {
        guard card != nil else { return }
        withAnimation(Motion.fade) {
            card = nil
            cardPath = nil
        }
    }

    /// "Can I trust them?": who they are, the people you follow who follow
    /// them (the post card's answer and words), and what you can do about it.
    /// Block sits behind "…" so it can't be hit by accident.
    func trustCard(_ pubkey: String) -> some View {
        let following = myFollows.contains(pubkey)
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys.contains(pubkey)
        let bridges = cardPath?.bridges ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name(pubkey)).font(.appSystem(size: 17, weight: .semibold)).lineLimit(1)
                    if let nip05 = nostrService.profiles[pubkey]?.nip05, !nip05.isEmpty {
                        Text(nip05).font(.appSystem(size: 13)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button { closeCard() } label: {
                    Image(systemName: "xmark")
                        .font(.appSystem(size: 13, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
            }
            HStack(spacing: 10) {
                if !bridges.isEmpty {
                    HStack(spacing: -10) {
                        ForEach(bridges, id: \.self) { bridge in
                            AvatarView(url: nostrService.profiles[bridge]?.pictureURL, pubkey: bridge, size: 26)
                                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 2))
                        }
                    }
                    .accessibilityHidden(true)
                }
                Text(TrustPathText.label(cardPath, name: name))
                    .font(.appSystem(size: 13))
                    .foregroundColor(cardPath?.reach == .outside ? .secondary : .primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                // The profile page's words: Unfollow says what the tap does.
                cardButton(following ? "Unfollow" : "Follow", icon: following ? "person.badge.minus" : "person.badge.plus",
                           filled: !following) {
                    FollowActions.toggle(pubkey, name: name(pubkey), isFollowing: following)
                }
                cardButton("Profile", icon: "person.crop.circle", filled: false) { profilePubkey = pubkey }
                // Already in the middle: there's no further web to move to.
                if pubkey != centerKey {
                    cardButton("See their web", short: "Their web", icon: "WoTTab", asset: true, filled: false) {
                        closeCard()
                        center(on: pubkey)
                    }
                    .accessibilityHint(Text("Puts \(name(pubkey)) in the middle, with the people they follow around them"))
                }
                Menu {
                    Button { messagePubkey = pubkey } label: { Label("Message", systemImage: "message") }
                    Divider()
                    Button(role: blocked ? nil : .destructive) { toggleBlock(pubkey, blocked: blocked) } label: {
                        Label(blocked ? "Unblock" : "Block", systemImage: blocked ? "hand.raised.slash" : "hand.raised")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 40, height: 38)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel(Text("More"))
            }
            .padding(.leading, 4)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        .padding(12)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    /// `short` stands in for `title` when a narrow phone has no room for it.
    private func cardButton(_ title: String, short: String? = nil, icon: String, asset: Bool = false, filled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if asset {
                    // A template image doesn't follow the font like an SF Symbol does.
                    Image(icon).resizable().frame(width: 13, height: 13)
                } else {
                    Image(systemName: icon).font(.appSystem(size: 12, weight: .semibold))
                }
                ViewThatFits(in: .horizontal) {
                    Text(title)
                    if let short { Text(short) }
                }
                .font(.appSystem(size: 14, weight: .semibold))
                .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .foregroundColor(filled ? .white : .havenPurple)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(Capsule().fill(filled ? Color.havenPurple : Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggleBlock(_ pubkey: String, blocked: Bool) {
        guard let data = Data(hex: pubkey), let npub = Bech32.encode(hrp: "npub", data: data) else { return }
        if blocked {
            ConfigService.shared.unblockProfile(npub)
        } else {
            ConfigService.shared.blockProfile(npub)
            closeCard()
        }
    }

    var wotSheetOpen: Bool { profilePubkey != nil || messagePubkey != nil }
}
