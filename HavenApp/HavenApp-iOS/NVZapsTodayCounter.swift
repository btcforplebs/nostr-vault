import Foundation

// MARK: - Zaps today counter
//
// How many zaps the active account has received since local midnight, for the
// Lock Screen widget's "Zaps today" (LockMetric.zaps).
//
// Read from your own relay, which already holds the receipts sent to you: no
// outside relay is asked. A receipt counts when it is signed (ZapHistoryService
// .query keeps only signed events), names you in its `p` tag, and passes
// ZapValidationService.isValidReceipt — the same check a receipt passes before
// it reaches the Vault's Zaps list (FeedService+NoteBatching). The rules live
// in NVZapsToday so they can be tested.

@MainActor
enum NVZapsTodayCounter {
    struct Count: Equatable {
        var account: String
        /// Local midnight the count started from.
        var dayStart: Date
        var count: Int
    }

    /// The last count your relay answered. A relay that does not answer
    /// leaves it in place.
    private(set) static var latest: Count?

    private static var inFlight = false
    private static var lastStarted: Date = .distantPast
    private static let minimumInterval: TimeInterval = 60

    /// The count to publish for `me`: nothing until one was made for this account.
    static func current(for me: String) -> Count? {
        guard let latest, latest.account == me else { return nil }
        return latest
    }

    /// Counts again, at most once a minute, and republishes the widgets when
    /// the number changed.
    static func refresh() {
        let me = ConfigService.shared.activeAccountHexPubkey
        let relay = RelayProcessManager.shared
        guard !me.isEmpty, !inFlight, relay.isRunning, !relay.isBooting,
              Date().timeIntervalSince(lastStarted) >= minimumInterval else { return }
        let base = ConfigService.shared.config.nostrURL
        // Zaps to you land in the inbox; the base path is asked too, as the
        // wallet history does.
        let relays = [base + "/inbox", base].compactMap { URL(string: $0) }
        guard !relays.isEmpty else { return }

        inFlight = true
        lastStarted = Date()
        Task { @MainActor in
            defer { inFlight = false }
            let now = Date()
            let dayStart = NVZapsToday.startOfDay(now)
            let since = Int(dayStart.timeIntervalSince1970)
            let filter: [String: Any] = ["kinds": [NVZapsToday.receiptKind], "#p": [me],
                                         "since": since, "limit": NVZapsToday.limit]
            var answered = false
            let events = await ZapHistoryService.query(filters: [filter], relays: relays,
                                                       onAnswered: { answered = true })
            guard answered || !events.isEmpty else { return }

            var receipts: [NVZapsToday.Receipt] = []
            for event in events {
                guard let receipt = NVZapsToday.Receipt(event: event),
                      await ZapValidationService.isValidReceipt(pubkey: receipt.publisher, recipientPubkey: me)
                else { continue }
                receipts.append(receipt)
            }
            // The account may have changed while the relay answered.
            guard ConfigService.shared.activeAccountHexPubkey == me else { return }
            let fresh = Count(account: me, dayStart: dayStart,
                              count: NVZapsToday.count(receipts, me: me, since: since))
            guard fresh != latest else { return }
            latest = fresh
            NVWidgetBridge.publish(force: true)
        }
    }
}
