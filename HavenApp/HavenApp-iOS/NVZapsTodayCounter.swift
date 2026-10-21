import Foundation

// MARK: - Zaps today counter
//
// How many zaps the active account has received since local midnight, for the
// Lock Screen widget's "Zaps today" (LockMetric.zaps).
//
// Read from your own relay, which already holds the receipts sent to you: no
// outside relay is asked. A receipt counts when it is signed, names you in its
// `p` tag, and passes ZapValidationService.isValidReceipt — the same check a
// receipt passes before it reaches the Vault's Zaps list
// (FeedService+NoteBatching). The rules live
// in NVZapsToday so they can be tested; the relay half is tested through
// `count(for:relays:at:using:)` with stand-in Checks.

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
            await count(for: me, relays: relays, at: Date(), using: .live)
        }
    }

    /// What one count asks of the outside world. The app always uses `live`;
    /// tests (MediaLogicTests) pass their own so the relay half can be checked.
    struct Checks {
        /// Asks `relays`, calling `onAnswered` when one ends its stored events (EOSE).
        var query: (_ filters: [[String: Any]], _ relays: [URL], _ onAnswered: @escaping () -> Void) async -> [[String: Any]]
        /// The event's id and signature are its own.
        var isSigned: ([String: Any]) -> Bool
        /// `publisher` may publish receipts on `me`'s behalf.
        var isValidReceipt: (_ publisher: String, _ me: String) async -> Bool
        var activeAccount: @MainActor () -> String
        var publish: @MainActor () -> Void

        static let live = Checks(
            query: { filters, relays, onAnswered in
                await ZapHistoryService.query(filters: filters, relays: relays, onAnswered: onAnswered)
            },
            // ZapHistoryService.query already keeps only signed events; checked
            // again here so the count does not rest on the query's internals.
            isSigned: { NostrEventVerifier.isValid($0) },
            isValidReceipt: { publisher, me in
                await ZapValidationService.isValidReceipt(pubkey: publisher, recipientPubkey: me)
            },
            activeAccount: { ConfigService.shared.activeAccountHexPubkey },
            publish: { NVWidgetBridge.publish(force: true) }
        )
    }

    /// Counts `me`'s receipts since the local midnight before `now` and keeps
    /// the result as `latest`, unless no relay answered or the account changed
    /// meanwhile. Republishes only when the number changed.
    static func count(for me: String, relays: [URL], at now: Date, using checks: Checks) async {
        let dayStart = NVZapsToday.startOfDay(now)
        let since = Int(dayStart.timeIntervalSince1970)
        let filter: [String: Any] = ["kinds": [NVZapsToday.receiptKind], "#p": [me],
                                     "since": since, "limit": NVZapsToday.limit]
        var answered = false
        let events = await checks.query([filter], relays, { answered = true })
        guard answered || !events.isEmpty else { return }

        var receipts: [NVZapsToday.Receipt] = []
        for event in events {
            guard checks.isSigned(event),
                  let receipt = NVZapsToday.Receipt(event: event),
                  await checks.isValidReceipt(receipt.publisher, me)
            else { continue }
            receipts.append(receipt)
        }
        // The account may have changed while the relay answered.
        guard checks.activeAccount() == me else { return }
        let fresh = Count(account: me, dayStart: dayStart,
                          count: NVZapsToday.count(receipts, me: me, since: since))
        guard fresh != latest else { return }
        latest = fresh
        checks.publish()
    }
}
