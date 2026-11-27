import Foundation

extension WebGate {
    /// A person on their own, with nothing they wrote: a follower, a liker.
    /// Inside means the gate would show a note they signed.
    static func isInside(_ pubkey: String, in web: Web) -> Bool {
        judge(Subject(signer: pubkey), in: web) == .inside
    }
}

/// Who the gate lets in, as the 16-character keys an `EngagementLedger`
/// saves (`EngagementLedger.key`), so a row's like and repost counts can
/// leave out people outside your web without judging each one.
///
/// Built once per gate and remembered: a profile list asks once per redraw,
/// and an unchanged gate compares by identity (`TrustedWebMemo` hands back
/// the same sets), so a repeat costs nothing.
final class GateInsideKeys: @unchecked Sendable {
    static let shared = GateInsideKeys()

    private let lock = NSLock()
    private var last: (gate: WebGate.Web, keys: Set<String>)?

    /// True for a key the gate judges inside: your accounts, the whitelist,
    /// your web, and not blocked or a public key (`WebGate.judge`).
    func predicate(for gate: WebGate.Web) -> (String) -> Bool {
        let keys = insideKeys(for: gate)
        return { keys.contains(String($0.prefix(16)).lowercased()) }
    }

    func insideKeys(for gate: WebGate.Web) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let last, last.gate == gate { return last.keys }
        let keys = Self.build(gate)
        last = (gate, keys)
        return keys
    }

    /// The same order as `WebGate.judge` for a bare signer.
    static func build(_ gate: WebGate.Web, isPublic: (String) -> Bool = { PublicKeyRegistry.shared.isPublic($0) }) -> Set<String> {
        var keys = Set<String>()
        for key in gate.own { keys.insert(EngagementLedger.key(key)) }
        for key in gate.whitelist.union(gate.web).union(gate.ranked)
        where !gate.own.contains(key) && !gate.blocked.contains(key) && !isPublic(key) {
            keys.insert(EngagementLedger.key(key))
        }
        return keys
    }
}
