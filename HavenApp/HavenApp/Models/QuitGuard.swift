import Foundation

/// Whether the Mac may quit now. A restore or backup holds the vault's
/// databases for its whole run, and quitting used to stop the relay with a
/// 5 s wait and exit mid-write: a half-applied restore, or a cut-short
/// backup. While one runs the app asks first, and can quit once it ends.
enum QuitGuard {
    enum Decision: Equatable {
        case quitNow
        /// Ask: quit when the job ends, or don't quit.
        case ask(title: String, detail: String)
    }

    /// The job names as `VaultBusyJob` raw values ("restoring", "backingUp",
    /// "importing"); a String so this file needs nothing from the app.
    static func decision(busyJob: String?) -> Decision {
        switch busyJob {
        case "restoring":
            return .ask(title: "A restore is still running",
                        detail: "Quitting now would leave your vault half restored. Nostr Vault can quit as soon as it finishes.")
        case "backingUp":
            return .ask(title: "A backup is still being made",
                        detail: "Quitting now would stop the backup before it's complete. Nostr Vault can quit as soon as it finishes.")
        default:
            // An import can be quit: it resumes, and each note it stores is
            // whole. Nothing else holds the databases.
            return .quitNow
        }
    }

    static let quitWhenDone = "Quit When It's Done"
    static let dontQuit = "Don't Quit"
}
