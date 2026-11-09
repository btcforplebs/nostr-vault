import Foundation

/// Files that hold private data on disk: config.json (the owner's key and
/// settings), its backup and unreadable copies, and the DM cache (decrypted
/// messages). Each write is atomic, readable only after the first unlock
/// since boot, and left out of iCloud and Finder backups. An atomic write
/// replaces the file, so the backup flag is set again after every write.
enum PrivateFile {
    static let writingOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: writingOptions)
        excludeFromBackup(url)
    }

    /// For a file made some other way (a copy, say).
    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
