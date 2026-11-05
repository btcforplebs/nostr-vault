import Foundation

/// A picked backup zip, read where it is (audit #17). Copying it to the temp
/// folder first made a big restore need the zip's size twice over, on top
/// of the restored data. The security scope is held until the engine has
/// finished reading, not just until the call returns.
enum ScopedImportFile {
    struct Access {
        var start: (URL) -> Bool
        var stop: (URL) -> Void
        /// Brings a file stored in iCloud Drive down to this device first.
        var download: (URL) -> Void

        static let system = Access(
            start: { $0.startAccessingSecurityScopedResource() },
            stop: { $0.stopAccessingSecurityScopedResource() },
            download: { url in
                var error: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { _ in }
            }
        )
    }

    /// Opens `url`, then calls `body` with its own path and a `finished` to
    /// call once the reader is done (it closes the scope, once).
    static func read(_ url: URL, access: Access = .system,
                     _ body: (_ path: String, _ finished: @escaping @Sendable () -> Void) -> Void) {
        // A file that needs no scope (the Mac's open panel, the app's own
        // folder) returns false here and is read all the same.
        let scoped = access.start(url)
        access.download(url)
        let once = Once()
        body(url.path) {
            guard once.first() else { return }
            if scoped { access.stop(url) }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
