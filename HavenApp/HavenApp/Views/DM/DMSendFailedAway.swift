import Foundation

/// A chat message that failed to send after you left the chat (B5): its
/// words go back as the chat's draft, unless you have typed a new one
/// since, and an error pill says what happened.
@MainActor
enum DMSendFailedAway {
    static func report(words: String, hadMedia: Bool, account: String,
                       counterparty: String, name: String?) {
        let drafts = DMDrafts.shared
        if !words.isEmpty, drafts.text(account: account, counterparty: counterparty) == nil {
            drafts.set(words, account: account, counterparty: counterparty)
        }
        let who = name ?? "them"
        let back = words.isEmpty ? "" : " Your text is back in the chat."
        let media = hadMedia ? " Attach the photo or video again." : ""
        ErrorNotificationManager.shared.show("Your message to \(who) didn't send.\(back)\(media)")
    }
}
