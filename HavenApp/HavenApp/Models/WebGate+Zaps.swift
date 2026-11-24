import Foundation

/// Zaps through the one gate (Logen 2026-11-18, call 4). A zap is judged on
/// the person who paid: the zap request's signer, and only when that request
/// verifies. From inside your web it shows whole. From outside it keeps its
/// amount and loses its words, so money still counts but nobody outside your
/// web can write to you through a zap comment. A blocked payer's zap goes.
extension WebGate {
    enum ZapShow: Equatable {
        /// Name, amount and comment.
        case whole
        /// The amount only: no comment.
        case amountOnly
        case hidden
    }

    static func zapShow(_ verdict: Verdict) -> ZapShow {
        switch verdict {
        case .inside: return .whole
        case .blocked: return .hidden
        case .outside, .loose: return .amountOnly
        }
    }

    /// A live chat row as the chat shows it, or nil when it goes. Chat from
    /// outside your web stays out. A zap from outside keeps its amount, and
    /// its comment goes. A zap with no verified payer (`authorPubkey` nil)
    /// names nobody, so it counts as outside.
    static func chatRow(_ row: LiveChatMessage, in gate: Web, always: Set<String>) -> LiveChatMessage? {
        guard row.isZap else {
            let subject = Subject(signer: row.authorPubkey ?? "", id: row.id, content: row.text)
            return judge(subject, in: gate, always: always) == .inside ? row : nil
        }
        let subject = Subject.zap(requestSigner: row.authorPubkey, verified: row.authorPubkey != nil,
                                  receiptId: row.id, comment: row.text)
        switch zapShow(judge(subject, in: gate, always: always)) {
        case .whole: return row
        case .hidden: return nil
        case .amountOnly:
            return LiveChatMessage(id: row.id, authorPubkey: row.authorPubkey, createdAt: row.createdAt,
                                   text: "", payload: row.payload)
        }
    }
}
