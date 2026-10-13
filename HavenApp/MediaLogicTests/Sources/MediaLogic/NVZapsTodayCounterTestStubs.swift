import Foundation

// Stand-ins for the app types NVZapsTodayCounter's `refresh()` and
// `Checks.live` name but that cannot build here (the relay process, the
// widget bridge, the Go signature check, the LNURL lookup). They cover only
// what the counter touches and are inert; the tests pass their own Checks to
// `count(for:relays:at:using:)` and nothing they assert on goes through these.

final class ConfigService {
    struct Config {
        var nostrURL = ""
    }

    static let shared = ConfigService()
    var activeAccountHexPubkey = ""
    var config = Config()
}

final class RelayProcessManager {
    static let shared = RelayProcessManager()
    var isRunning = false
    var isBooting = false
}

enum ZapHistoryService {
    static func query(filters: [[String: Any]], relays: [URL], timeout: TimeInterval = 5,
                      onProgress: (([[String: Any]]) -> Void)? = nil,
                      onAnswered: (() -> Void)? = nil) async -> [[String: Any]] {
        []
    }
}

enum ZapValidationService {
    static func isValidReceipt(pubkey receiptPubkey: String, recipientPubkey: String) async -> Bool {
        false
    }
}

enum NostrEventVerifier {
    static func isValid(_ event: [String: Any]) -> Bool {
        false
    }
}

enum NVWidgetBridge {
    static func publish(force: Bool = false) {}
}
