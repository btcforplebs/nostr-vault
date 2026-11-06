import Foundation

/// What Factory Reset (`ConfigService.resetApp`) leaves behind, deleted for
/// "Delete Account": the caches beside config.json (profiles, relay lists,
/// DM caches named after the account), the app's Caches and temp folders and
/// its UserDefaults (settings, many keyed by the account's pubkey).
/// Only the app's own storage: a sandboxed container, or folders named for
/// this app.
enum AppDataWipe {
    static func clearRest(appSupport: URL, bundleID: String = Bundle.main.bundleIdentifier ?? "") {
        let fm = FileManager.default
        removeContents(of: appSupport, fm: fm)
        for dir in ownCacheFolders(bundleID: bundleID, fm: fm) { removeContents(of: dir, fm: fm) }
        removeContents(of: fm.temporaryDirectory, fm: fm)
        if !bundleID.isEmpty {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            UserDefaults.standard.synchronize()
        }
    }

    /// The whole Caches folder in a sandbox (iOS, the Mac App Store app);
    /// otherwise only the folders this app names.
    private static func ownCacheFolders(bundleID: String, fm: FileManager) -> [URL] {
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return [] }
        #if os(macOS)
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        if !sandboxed {
            return [bundleID, "Wavlake"].filter { !$0.isEmpty }.map { caches.appendingPathComponent($0, isDirectory: true) }
        }
        #endif
        return [caches]
    }

    /// A second pass on iOS, once services that were still running have
    /// written their caches back: the caches beside config.json only. A new
    /// setup started meanwhile keeps its config, vault folder and settings.
    static func sweepCaches(appSupport: URL) {
        removeContents(of: appSupport, fm: .default, keeping: ["config.json", "haven_database"])
    }

    private static func removeContents(of dir: URL, fm: FileManager, keeping: Set<String> = []) {
        // Never a root or home folder by mistake.
        guard dir.path.count > 10, dir.path != NSHomeDirectory(),
              let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in items where !keeping.contains(item.lastPathComponent) { try? fm.removeItem(at: item) }
    }
}
