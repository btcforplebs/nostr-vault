import SwiftUI
import Combine
import ImageIO
#if os(iOS)
import Photos
#endif

extension ProfileContent {
    // MARK: - Banner

    /// A strip a third as tall as it is wide, the same with or without a
    /// banner (a tinted wash stands in), so nothing below it moves when the
    /// profile or its banner arrives.
    private var bannerHeight: CGFloat {
        let width = viewportWidth > 0 ? viewportWidth : 390
        return min(max(width / 3, 110), 210)
    }

    var bannerHeader: some View {
        ProfileBannerView(
            bannerURL: profile?.bannerURL,
            avatarURL: profile?.pictureURL,
            pubkey: pubkey,
            height: bannerHeight,
            topInset: topInset,
            onTap: { url in showingMediaUrl = IdentifiableURL(url: url) }
        )
        .overlay(alignment: .top) {
            if let dismissAction { dismissHeader(dismissAction) }
        }
    }

    /// Sits on the banner, so it carries its own dark disc instead of relying
    /// on the page behind it.
    private func dismissHeader(_ action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(action: action) {
                Image(systemName: "xmark.circle.fill")
                    .font(.appSystem(size: 24))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white.opacity(0.9), .black.opacity(0.45))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    var divider: some View {
        Rectangle()
            .fill(Color.platformSeparator.opacity(0.6))
            .frame(height: 0.5)
            .padding(.vertical, 16)
    }

    // MARK: - Header block

    var headerBlock: some View {
        HStack(alignment: .top, spacing: 14) {
            AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 72)
                .overlay(
                    Circle().stroke(Color.havenPurple.opacity(0.35), lineWidth: 1.5)
                )
                // A ring in the page color lifts the avatar off the banner.
                .padding(3)
                .background(Circle().fill(Color.platformWindowBackground))
                // Half over the banner; the name column stays below it.
                .padding(.top, -36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile?.bestName ?? ProfileFormat.shortPubkey(pubkey))
                        .font(.appSystem(size: 20, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if let nip05 = profile?.nip05, !nip05.isEmpty {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.appSystem(size: 13))
                            .foregroundColor(Color.havenVerified)
                    }

                    Spacer(minLength: 0)

                    badge()
                }

                if let nip05 = profile?.nip05, !nip05.isEmpty {
                    Text(nip05)
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else if awaitingMetadata {
                    Text("name@example.com")
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .redacted(reason: .placeholder)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - Metadata placeholders

    /// No kind 0 for this person yet. The header holds the space the NIP-05
    /// line, a short bio and the Lightning row usually take, so the tabs and
    /// notes are not pushed down when they arrive.
    var awaitingMetadata: Bool {
        guard !metadataWaitOver else { return false }
        guard let p = profile else { return true }
        return p.name == nil && p.displayName == nil && p.about == nil
            && p.pictureURL == nil && p.nip05 == nil && p.lud16 == nil
    }

    var bioPlaceholder: some View {
        Text("A short bio about this person, about as long as most are, two lines.")
            .font(.appSystem(size: 13))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
    }

    var linksPlaceholder: some View {
        linkChip("name@wallet.example", icon: "bolt.fill", tint: .secondary)
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
    }

    // MARK: - Bio

    func bioBlock(_ about: String) -> some View {
        Text(about)
            .font(.appSystem(size: 13))
            .foregroundColor(.primary.opacity(0.85))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
    }

    // MARK: - Action row

    /// One line, never scrolled. When space runs out (small phones, large
    /// text) the screen's own row drops words, tightest last.
    var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            actions(0).fixedSize(horizontal: false, vertical: true)
            actions(1).fixedSize(horizontal: false, vertical: true)
            actions(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Follow counts

    /// One line under the links. The Notes and Media counts already sit on
    /// their tabs, so only the two that open somewhere else are here.
    var followCountsRow: some View {
        HStack(spacing: 18) {
            Button { openFollowList(.following) } label: {
                followCount(loader.followingCountShown.map(ProfileFormat.shortInt) ?? "—", label: "Following")
            }
            Button { openFollowList(.followers) } label: {
                followCount(loader.displayedFollowersCount.map(ProfileFormat.shortInt) ?? "—", label: "Followers")
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func followCount(_ value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.appSystem(size: 14, weight: .bold))
                .monospacedDigit()
                .foregroundColor(.primary)
            Text(label)
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
        }
        .lineLimit(1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Follow lists

    /// Reads the viewer's ledger first, then opens. Opening first built the
    /// page without it: your own Followers showed the relays' sample with a
    /// "load more", then swapped to the full list a moment later.
    private func openFollowList(_ tab: FollowListTab) {
        let viewer = configService.activeAccountHexPubkey
        Task.detached(priority: .userInitiated) {
            let ledger = FollowerSnapshot.load(owner: viewer)
            await MainActor.run {
                viewerLedger = ledger
                followListTab = tab
            }
        }
    }

    func followListPage(startOn tab: FollowListTab) -> some View {
        let ledger = viewerLedger
        let viewerFollowers = ledger.map { Set($0.current.map(\.pubkey)) } ?? []
        let spam = ledger.map { Set($0.followers.filter(\.isSpam).map(\.pubkey)) } ?? []
        // Your own followers come from the relay's ledger, which is complete.
        // Anyone else's are what relays returned, which may be short.
        let ownLedger = loader.usesOwnLedger ? ledger : nil
        let followers: [String: Int64] = ownLedger.map { snap in
            Dictionary(snap.current.map { ($0.pubkey, $0.existing ? $0.listAt : $0.followedAt) }, uniquingKeysWith: max)
        } ?? loader.followerSeenAt
        let haveMore = ownLedger == nil && !loader.followersExhausted
            && (loader.displayedFollowersCount ?? 0) > followers.count
        return FollowListView(
            subject: pubkey,
            subjectName: profile?.bestName ?? ProfileFormat.shortPubkey(pubkey),
            startOn: tab,
            following: loader.followingPubkeys,
            followers: followers,
            followersHaveMore: haveMore,
            followerPagesDone: loader.followerPagesDone,
            followersTotal: ownLedger == nil ? loader.displayedFollowersCount : nil,
            isViewersOwnFollowers: ownLedger != nil,
            followsViewer: viewerFollowers,
            hidden: spam,
            onLoadMoreFollowers: ownLedger == nil ? { loader.loadMoreFollowers() } : nil
        )
        .environmentObject(nostrService)
        .environmentObject(configService)
    }

    // MARK: - Links

    private var lightningAddress: String? {
        guard let profile else { return nil }
        if let lud06 = profile.lud06, !lud06.isEmpty { return "lnurl:" + lud06 }
        if let lud16 = profile.lud16, !lud16.isEmpty { return lud16 }
        return nil
    }

    private var formattedNpub: String {
        if let npub = ProfileFormat.npub(pubkey) {
            return String(npub.prefix(12)) + "…" + String(npub.suffix(8))
        }
        return "npub…" + String(pubkey.suffix(8))
    }

    /// Lightning address, website and npub, one wrapping row of chips in
    /// place of a table row each. Tap copies, or opens the website.
    var linksRow: some View {
        ProfileChipFlow(spacing: 8) {
            if let lud16 = lightningAddress {
                Button { ProfileFormat.copy(lud16); flash($copiedLightning) } label: {
                    linkChip(lud16, icon: copiedLightning ? "checkmark" : "bolt.fill",
                             tint: copiedLightning ? .green : .orange)
                }
                .accessibilityLabel(copiedLightning ? "Lightning address copied" : "Copy Lightning address \(lud16)")
            }
            if let website = profile?.website, !website.isEmpty,
               let url = URL(string: website.hasPrefix("http") ? website : "https://\(website)") {
                let shown = website.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
                Button { openURL(url) } label: {
                    linkChip(shown, icon: "globe", tint: .havenPurple)
                }
                .accessibilityLabel("Open \(shown)")
            }
            Button {
                if let npub = ProfileFormat.npub(pubkey) { ProfileFormat.copy(npub); flash($copiedNpub) }
            } label: {
                linkChip(formattedNpub, icon: copiedNpub ? "checkmark" : "key.fill",
                         tint: copiedNpub ? .green : .secondary)
            }
            .accessibilityLabel(copiedNpub ? "Public key copied" : "Copy public key")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func flash(_ flag: Binding<Bool>) {
        flag.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            flag.wrappedValue = false
        }
    }

    private func linkChip(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.appSystem(size: 10, weight: .bold))
                .foregroundColor(tint)
            Text(text)
                .font(.appSystem(size: 12, weight: .medium))
                .foregroundColor(.primary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
        .contentShape(Capsule())
    }
}
