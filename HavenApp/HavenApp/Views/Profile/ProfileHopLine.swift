import SwiftUI

/// Under a profile's name: "2 hops · followed by Alice, Bob and 3 more", or
/// "4 hops" for someone only your Haven reaches (`ProfileHopText`). Nothing
/// for you, or for someone neither your web nor your Haven knows. Android
/// twin: `ui/screens/profile/ProfileHopLine.kt`.
///
/// Draws nothing until it knows, so the path and the copy start loading when
/// the view is made (`.task` never runs on a view that draws nothing). One
/// line per person: the caller gives it `.id(pubkey)`.
struct ProfileHopLine: View {
    let pubkey: String
    @EnvironmentObject var nostrService: NostrService
    @ObservedObject private var config = ConfigService.shared
    @StateObject private var trust: LiveTrustPath
    @StateObject private var rank = TrustRankCopyWatch()

    init(pubkey: String) {
        self.pubkey = pubkey
        _trust = StateObject(wrappedValue: {
            let trust = LiveTrustPath()
            if pubkey != ConfigService.shared.activeAccountHexPubkey { trust.track(pubkey) }
            return trust
        }())
    }

    private var me: String { config.activeAccountHexPubkey }

    var body: some View {
        if let line = ProfileHopText.line(pubkey: pubkey, me: me, path: trust.path, rank: rank.copy?[pubkey],
                                          name: name) {
            Text(line)
                .font(.appSystem(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .task(id: trust.path) {
                    let path = trust.path
                    let named = Array((path.map { $0.all.isEmpty ? $0.bridges : $0.all } ?? []).prefix(ProfileHopText.named))
                    if !named.isEmpty { nostrService.fetchMissingProfiles(for: named) }
                }
        }
    }

    private func name(_ pk: String) -> String {
        nostrService.profiles[pk]?.bestName ?? "npub…\(pk.suffix(6))"
    }
}
