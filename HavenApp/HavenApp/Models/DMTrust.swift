import Foundation

/// Who reaches the Messages inbox. A gift-wrapped DM is signed by a throwaway
/// key, so the relay stores every wrap tagged to you whoever sent it; only the
/// opened message names the person, and this check runs on that real sender.
///
/// A conversation is in the inbox when the other person is in your Web of
/// Trust (you, the people you follow, and the web the relay built from them)
/// or when you have written to them. Following you is not trust: anyone can
/// follow anyone. Everyone else waits under Requests, unread but silent, and
/// answering moves the conversation into the inbox.
///
/// Fails closed: with no trust graph yet, only conversations you took part in
/// reach the inbox.
enum DMTrust {
    static func isInbox(counterparty: String, youWrote: Bool,
                        trusted: Set<String>, own: Set<String>) -> Bool {
        if youWrote { return true }
        let key = counterparty.lowercased()
        if own.contains(where: { $0.lowercased() == key }) { return true }
        return trusted.contains(key) || trusted.contains(counterparty)
    }

    /// Splits conversations into the inbox and Requests, keeping their order.
    static func split<C>(_ conversations: [C], trusted: Set<String>, own: Set<String>,
                         counterparty: (C) -> String,
                         youWrote: (C) -> Bool) -> (inbox: [C], requests: [C]) {
        var inbox: [C] = []
        var requests: [C] = []
        for c in conversations {
            if isInbox(counterparty: counterparty(c), youWrote: youWrote(c), trusted: trusted, own: own) {
                inbox.append(c)
            } else {
                requests.append(c)
            }
        }
        return (inbox, requests)
    }
}
