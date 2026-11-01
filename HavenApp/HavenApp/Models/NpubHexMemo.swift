import Foundation

/// Remembers the hex keys of the last npub list it was asked about. The
/// trusted and blocked sets were bech32-decoded again for every injected note,
/// every thread redraw and every tab bar redraw (Tom's perf sweep 11-01 #6);
/// comparing the list with the last one is far cheaper than decoding it.
/// Safe from any thread.
final class NpubHexMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var lastInput: [String]?
    private var lastOutput: Set<String> = []
    private var lastOne: (npub: String, hex: String?)?

    /// The hex keys of `npubs`, blanks and undecodable entries skipped.
    func hexSet(_ npubs: [String]) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let lastInput, lastInput == npubs { return lastOutput }
        let out = Self.decode(npubs)
        lastInput = npubs
        lastOutput = out
        return out
    }

    /// The hex key of one npub (trimmed), nil when it doesn't decode.
    func hex(_ npub: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let lastOne, lastOne.npub == npub { return lastOne.hex }
        let hex = Bech32.decode(npub.trimmingCharacters(in: .whitespacesAndNewlines))?.hexString
        lastOne = (npub, hex)
        return hex
    }

    static func decode(_ npubs: [String]) -> Set<String> {
        var out = Set<String>()
        for npub in npubs {
            let clean = npub.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, let decoded = Bech32.decode(clean) { out.insert(decoded.hexString) }
        }
        return out
    }
}
