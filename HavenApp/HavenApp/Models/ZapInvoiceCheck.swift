import Foundation

/// Whether an invoice a zap server sent back may be paid. LUD-06: it must be
/// for exactly the msat asked for, or a server could charge more (or a 21-sat
/// zap could pay a 100k-sat invoice), and it must not have expired. The share
/// pay path checks the same (PayShareHandler.payLNURL).
///
/// Pure Foundation so MediaLogicTests can test it.
enum ZapInvoiceCheck {
    enum Problem: Equatable {
        /// Not exactly the amount asked for (or no readable amount).
        case wrongAmount
        case expired
    }

    static func problem(invoice: String, amountMsat: Int, now: Date = Date()) -> Problem? {
        guard Bolt11.msat(invoice) == amountMsat else { return .wrongAmount }
        if let details = Bolt11.details(invoice), details.isExpired(at: now) { return .expired }
        return nil
    }
}
