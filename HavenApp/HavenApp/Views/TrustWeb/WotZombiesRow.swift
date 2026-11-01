import SwiftUI

#if os(iOS)
/// The vault's zombie check (`WotZombiesC`) for the active account: started
/// when My Web opens, polled while it runs, reused for a day by the vault.
@MainActor
final class WotZombiesStore: ObservableObject {
    static let shared = WotZombiesStore()

    @Published private(set) var state: WotZombies.State?
    private var owner = ""
    private var polling: Task<Void, Never>?

    /// The report as it stands now: only people still followed.
    var report: WotZombies.Report? {
        guard let report = state?.report, report.owner == owner else { return nil }
        let feed = FeedService.shared
        // An empty list means not loaded yet, not "follows nobody".
        guard !feed.followedPubkeys.isEmpty else { return report }
        return report.keeping(following: Set(feed.followedPubkeys))
    }

    var checking: Bool { state?.checking ?? (polling != nil) }

    func load(force: Bool = false) {
        let account = ConfigService.shared.activeAccountHexPubkey
        if account != owner {
            owner = account
            state = nil
        }
        guard !account.isEmpty else { return }
        polling?.cancel()
        polling = Task { [weak self] in
            var force = force
            // A check on ~1,000 follows took ~40 s in the dry run; give up
            // polling after 3 minutes, the next open asks again.
            for _ in 0..<90 {
                let next = await Self.read(owner: account, force: force)
                force = false
                guard let self, !Task.isCancelled, account == self.owner else { return }
                self.state = next
                if next?.checking != true { break }
                try? await Task.sleep(for: .seconds(2))
            }
            self?.polling = nil
        }
    }

    private nonisolated static func read(owner: String, force: Bool) async -> WotZombies.State? {
        await Task.detached(priority: .utility) {
            guard let ptr = owner.withCString({ WotZombiesC(UnsafeMutablePointer(mutating: $0), force ? 1 : 0) }) else {
                return nil
            }
            defer { free(ptr) }
            return WotZombies.State.decode(String(cString: ptr))
        }.value
    }
}

/// My Web's zombie card: the count, the three buckets, and the way into the
/// list, and the button to Plebs vs. Zombies. The 10-31 mockups, read-only.
struct WotZombiesCard: View {
    @ObservedObject var store = WotZombiesStore.shared
    @ObservedObject private var feed = FeedService.shared

    var body: some View {
        DashboardSection(title: "Zombies in your web") {
            if let report = store.report {
                NavigationLink {
                    WotZombiesList()
                } label: {
                    headline(report)
                }
                .buttonStyle(.plain)
                .disabled(report.zombies.isEmpty)
                if !report.zombies.isEmpty {
                    Divider().padding(.leading, 14)
                    buckets(report)
                }
                if !report.zombies.isEmpty {
                    PlebsVsZombiesButton()
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
            } else if let error = store.state?.error, !store.checking {
                status(error == "relay not running" ? "Shows once your vault is running"
                                                    : "Zombies show for an account on this vault")
            } else {
                status("Checking who's been quiet…", spinning: true)
            }
        }
        .onAppear { store.load() }
    }

    private func headline(_ report: WotZombies.Report) -> some View {
        HStack(spacing: 12) {
            ZombieIcon()
            VStack(alignment: .leading, spacing: 2) {
                Text(WotZombies.headline(quiet: report.zombies.count, follows: report.follows))
                    .font(.appSystem(size: 16, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing signed by them in that time")
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            if !report.zombies.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(report.zombies.isEmpty ? "" : "Lists them, quiet longest first"))
    }

    private func buckets(_ report: WotZombies.Report) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(WotZombies.Bucket.allCases.enumerated()), id: \.element) { index, bucket in
                if index > 0 { Divider().frame(height: 44) }
                VStack(spacing: 2) {
                    Text(report.count(bucket).formatted())
                        .font(.appSystem(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundColor(bucket.color)
                    Text(bucket.title)
                        .font(.appSystem(size: 14, weight: .semibold))
                    Text(bucket.daysText)
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 12)
    }

    private func status(_ text: String, spinning: Bool = false) -> some View {
        HStack(spacing: 12) {
            ZombieIcon()
            Text(text)
                .font(.appSystem(size: 15))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            if spinning { ProgressView() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// The card's icon: 🧟 (Plebs vs. Zombies' own, with their OK).
private struct ZombieIcon: View {
    var body: some View {
        Text("🧟")
            .font(.system(size: 24))
            .frame(width: 40, height: 40)
            .background(Color.havenPurple.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

extension WotZombies.Bucket {
    var color: Color {
        switch self {
        case .fresh: return .yellow
        case .rotting: return .orange
        case .ancient: return .red
        }
    }
}

/// The quiet follows, longest first. Read-only: cleaning up happens on
/// Plebs vs. Zombies, never in this app (Logen 2026-11-01).
struct WotZombiesList: View {
    @ObservedObject var store = WotZombiesStore.shared
    @ObservedObject private var nostr = NostrService.shared

    var body: some View {
        let zombies = store.report?.zombies ?? []
        List {
            Section {
                ForEach(zombies) { zombie in
                    row(zombie)
                }
            } header: {
                Text(WotZombies.listHeader(quiet: zombies.count))
                    .textCase(nil)
            }
        }
        .navigationTitle("Zombies")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            PlebsVsZombiesButton()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .onAppear { nostr.fetchMissingProfiles(for: zombies.prefix(300).map(\.pubkey)) }
    }

    private func row(_ zombie: WotZombies.Zombie) -> some View {
        let profile = nostr.profiles[zombie.pubkey]
        return HStack(spacing: 12) {
            AvatarView(url: profile?.pictureURL, pubkey: zombie.pubkey, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.bestName ?? Self.shortNpub(zombie.pubkey))
                    .font(.appSystem(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(WotZombies.lastSeenText(zombie.lastSeen))
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Text(zombie.bucket.title)
                .font(.appSystem(size: 12, weight: .bold))
                .foregroundColor(zombie.bucket.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(zombie.bucket.color.opacity(0.16)))
        }
        .accessibilityElement(children: .combine)
    }

    private static func shortNpub(_ hex: String) -> String {
        let npub = Bech32.encode(hrp: "npub", data: Data(hexString: hex) ?? Data()) ?? hex
        return String(npub.prefix(16)) + "…"
    }
}

/// Opens Plebs vs. Zombies in the browser, where the owner cleans up. The
/// app itself never unfollows anyone for this.
struct PlebsVsZombiesButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(WotZombies.plebsVsZombiesURL)
        } label: {
            Text("Clean up on Plebs vs Zombies")
                .font(.appSystem(size: 16, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.havenPurple)
        .accessibilityHint(Text("Opens plebsvszombies.cc in your browser"))
    }
}
#endif
