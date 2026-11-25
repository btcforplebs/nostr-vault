import Foundation

// Zaps that went through but looked failed (RESEARCH/NV_MINIBITS_ZAP_REVIEW_2026_11_19.md,
// Logen 2026-11-19). Pure rules, shared with MediaLogicTests: how long to wait for the wallet,
// which receipt is ours, and when a second zap to the same note should ask first.

/// How long a zap waits for each answer.
enum ZapWait {
    /// Reaching the wallet's NWC relay and sending `pay_invoice`. Nothing has been sent before
    /// this, so running out of time here is a real failure.
    static let connect: TimeInterval = 15
    /// The wallet's reply once `pay_invoice` is out. Paid zaps took up to 96 s on 2026-11-19, so
    /// 15 s called most of them failed. Running out of time here means "may still pay", not failed.
    static let reply: TimeInterval = 90
    /// How long to look for our own zap receipt (kind 9735), from when the invoice is paid.
    /// Push-woken wallets such as Minibits can pay minutes later (cashu design §6c), so this is
    /// the pending zap's whole `ZapPendingGuard.window`, not 30 s past the reply wait.
    static let receipt: TimeInterval = 600
    /// Between two looks for the receipt.
    static let receiptPoll: TimeInterval = 6
}

/// What a zap's NWC wait comes to when the wallet hasn't said paid or failed.
enum ZapWaitOutcome: Equatable {
    /// Nothing reached the wallet: the zap did not happen.
    case failed
    /// The request is out; the wallet may still pay. The receipt decides.
    case pending

    /// Out of time, or the socket went away, with or without `pay_invoice` sent.
    static func noAnswer(requestSent: Bool) -> ZapWaitOutcome { requestSent ? .pending : .failed }
}

/// Whether a kind 9735 receipt is the one for our zap.
enum ZapReceiptMatch {
    /// - Parameters:
    ///   - publisher: the recipient's LNURL `nostrPubkey`, when it names one. A receipt from anyone
    ///     else is not trusted (ZapValidationService), even if it quotes our request.
    ///   - zapRequestId: our signed 9734's id, which the server copies into `description`.
    ///   - invoice: the bolt11 we paid, which the server copies into `bolt11`.
    static func matches(receiptPubkey: String, tags: [[String]], zapRequestId: String, invoice: String,
                        publisher: String?) -> Bool {
        if let publisher, !publisher.isEmpty, receiptPubkey.lowercased() != publisher.lowercased() { return false }
        if let bolt11 = value("bolt11", in: tags), !invoice.isEmpty,
           bolt11.lowercased() == invoice.lowercased() { return true }
        guard let description = value("description", in: tags),
              let data = description.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = request["id"] as? String else { return false }
        return !zapRequestId.isEmpty && id.lowercased() == zapRequestId.lowercased()
    }

    private static func value(_ name: String, in tags: [[String]]) -> String? {
        tags.first { $0.count >= 2 && $0[0] == name }?[1]
    }
}

/// Zaps still waiting on a receipt, by what they zap, so a second tap asks before paying again
/// (the 2x 1,000 sats to the same address 26 s apart on 2026-11-19).
struct ZapPendingGuard {
    /// A pending zap stops counting after this, receipt or not.
    static let window: TimeInterval = 600

    private var started: [String: Date] = [:]

    /// One key per zapped thing: the note, else the stream or article address, else the person.
    static func key(noteId: String, address: String?, pubkey: String) -> String {
        if !noteId.isEmpty { return "e:\(noteId.lowercased())" }
        if let address, !address.isEmpty { return "a:\(address)" }
        return "p:\(pubkey.lowercased())"
    }

    func isPending(_ key: String, now: Date = Date()) -> Bool {
        guard let at = started[key] else { return false }
        return now.timeIntervalSince(at) < Self.window
    }

    mutating func begin(_ key: String, now: Date = Date()) { started[key] = now }

    mutating func end(_ key: String) { started[key] = nil }
}

/// "Zap:" and "NWC:" lines are also written to relay.log, so a zap that looked failed can be
/// read back off the device afterwards (they used to live only in memory).
enum ZapLogLine {
    static func isZapLine(_ message: String) -> Bool { message.hasPrefix("Zap:") || message.hasPrefix("NWC:") }

    /// In the relay's own `2006/01/02 15:04:05 LEVEL message` shape, which the log parser reads
    /// back into Settings > Logs with its level.
    static func line(_ message: String, level: String, at date: Date = Date()) -> String {
        "\(stamp.string(from: date)) \(level.uppercased()) \(message.replacingOccurrences(of: "\n", with: " "))\n"
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return f
    }()
}
