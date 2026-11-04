import Foundation

/// Fetches the notes Vault lines point at when they aren't in memory: the
/// likes, reposts and zaps on your notes that `VaultActivity.build` keeps a
/// line for before the note itself has loaded, or on notes older than the
/// ones the vault list asks for (Logen 2026-11-04,
/// RESEARCH/NV_LIVE_VAULT_LOAD_ORDER.md). Shared by the Vault list and the
/// iPad's Live Vault panel, so a note is asked for once whichever of them
/// built the line. Fetched notes land in `NostrService.events` and the next
/// rebuild fills in the lines' previews.
@MainActor
final class ActivityTargetFetcher {
    static let shared = ActivityTargetFetcher()

    /// At most this many ids per ask.
    static let batch = 100

    private var asked = Set<String>()
    private var generation = -1

    /// `lines` as built; `have` the ids already in memory.
    func fetch(_ lines: [VaultActivity], have: Set<String>,
               nostrService: NostrService = .shared, configService: ConfigService = .shared) {
        // A refresh drops the fetched notes with the rest: ask again.
        if generation != nostrService.eventsResetGeneration {
            generation = nostrService.eventsResetGeneration
            asked = []
        }
        let wanted = VaultActivity.missingTargets(in: lines, have: have).filter { !asked.contains($0) }
        guard !wanted.isEmpty else { return }
        let ids = Array(wanted.prefix(Self.batch))
        asked.formUnion(ids)
        // Your own notes: from where yours are kept (the vault and the Mac
        // relay, not their inboxes) and your write relays.
        let (urls, _) = VaultView.activitySources(configService)
        let own = configService.config.writeRelays.compactMap { URL(string: $0) }
        nostrService.fetchNotesByIds(ids, from: urls.filter { !$0.absoluteString.hasSuffix("/inbox") } + own.prefix(4))
    }
}
