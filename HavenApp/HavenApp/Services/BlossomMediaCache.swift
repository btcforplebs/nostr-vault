import Foundation
import SwiftUI

extension Notification.Name {
    static let blossomDirectoryChanged = Notification.Name("blossomDirectoryChanged")
}

/// Watches a directory for filesystem changes (new files written by the relay process).
/// Detects when external devices (e.g. phone) upload blobs to the Mac relay.
class BlossomDirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?

    /// False when the folder can't be opened, so the caller tries again later.
    @discardableResult
    func start(directory: URL) -> Bool {
        stop()

        // A new vault has no media folder until its first file; create it so
        // the first file is seen too.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.debounceWorkItem?.cancel()
            let work = DispatchWorkItem {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .blossomDirectoryChanged, object: nil)
                }
            }
            self?.debounceWorkItem = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        self.source = source
        return true
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}

/// Singleton cache for blossom media items. Persists across tab switches and
/// background/foreground cycles so the media grid doesn't need to rescan the
/// filesystem every time the view appears.
@MainActor
class BlossomMediaCache: ObservableObject {
    static let shared = BlossomMediaCache()

    @Published var items: [MediaItem] = []
    @Published var isScanning: Bool = false
    /// Bumped when a scan finds a different set of files; the gallery redraws on it.
    @Published var revision: Int = 0
    /// One scan at a time without dropping a request (MediaRescanGate).
    var rescanGate = MediaRescanGate()

    /// Timestamp of the last completed filesystem scan.
    var lastScanDate: Date?

    private let directoryWatcher = BlossomDirectoryWatcher()
    private var watchedDirectory: URL?

    private init() {}

    /// Returns true if the cache was populated recently enough to skip a rescan.
    /// Default staleness threshold is 5 seconds.
    func isFresh(threshold: TimeInterval = 5.0) -> Bool {
        guard let lastScan = lastScanDate else { return false }
        return Date().timeIntervalSince(lastScan) < threshold
    }

    /// Begin monitoring the blossom directory for external changes (e.g. phone uploads to Mac relay).
    func startWatchingIfNeeded(directory: URL) {
        guard watchedDirectory != directory else { return }
        // Only remembered once it is watched: a folder that couldn't be opened
        // used to be marked watched anyway, and was never watched after.
        if directoryWatcher.start(directory: directory) { watchedDirectory = directory }
    }

    func stopWatching() {
        directoryWatcher.stop()
        watchedDirectory = nil
    }
}
