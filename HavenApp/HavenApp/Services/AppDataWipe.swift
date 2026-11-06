import Foundation

/// What Factory Reset (`ConfigService.resetApp`) leaves behind, deleted for
/// "Delete Account": the caches beside config.json (profiles, relay lists,
/// DM caches named after the account), the app's Caches and temp folders and
/// its UserDefaults (settings, many keyed by the account's pubkey).
/// Only the app's own storage: a sandboxed container, or folders named for
/// this app.
enum AppDataWipe {
    /// The App Group the iOS app shares with its share extension.
    static let appGroup = "group.com.havenapp.relay"

    static func clearRest(appSupport: URL, bundleID: String = Bundle.main.bundleIdentifier ?? "") {
        let fm = FileManager.default
        removeContents(of: appSupport, fm: fm)
        for dir in ownCacheFolders(bundleID: bundleID, fm: fm) { removeContents(of: dir, fm: fm) }
        removeContents(of: fm.temporaryDirectory, fm: fm)
        // iOS: the App Group shared with the share extension (ShareInbox:
        // photos and videos shared in, waiting to upload) and its defaults.
        // The Mac app has no App Group (asking there can raise a privacy prompt).
        #if os(iOS)
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            removeContents(of: group, fm: fm)
        }
        UserDefaults(suiteName: appGroup)?.removePersistentDomain(forName: appGroup)
        #endif
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
    /// Also drops any setting whose name holds the deleted account's pubkey
    /// (`followersSeenAt.<hex>` and the like, written back by open screens).
    static func sweepCaches(appSupport: URL, forgetting hex: String) {
        removeContents(of: appSupport, fm: .default, keeping: ["config.json", "haven_database"])
        let hex = hex.lowercased()
        guard hex.count == 64 else { return }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.lowercased().contains(hex) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Delete Account for one account (not the main one): deletes the files
    /// beside config.json and in the app's caches whose names hold that
    /// account's hex pubkey or npub, and the settings named after it
    /// (`AccountDataSweep`). The vault database and config.json are not
    /// touched; `ConfigService.removeAccount` takes the account out of the
    /// config.
    static func forgetAccount(hex: String, npub: String, appSupport: URL,
                              bundleID: String = Bundle.main.bundleIdentifier ?? "") {
        let fm = FileManager.default
        var roots = [appSupport]
        roots += ownCacheFolders(bundleID: bundleID, fm: fm)
        for root in roots { removeNamed(in: root, hex: hex, npub: npub, fm: fm) }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where AccountDataSweep.belongs(key, hex: hex, npub: npub) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func removeNamed(in root: URL, hex: String, npub: String, fm: FileManager) {
        guard root.path.count > 10, root.path != NSHomeDirectory(),
              let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        var doomed: [URL] = []
        for case let item as URL in walker {
            let name = item.lastPathComponent
            if AccountDataSweep.skipped.contains(name) { walker.skipDescendants(); continue }
            if AccountDataSweep.belongs(name, hex: hex, npub: npub) {
                doomed.append(item)
                walker.skipDescendants()
            }
        }
        for item in doomed { try? fm.removeItem(at: item) }
    }

    private static func removeContents(of dir: URL, fm: FileManager, keeping: Set<String> = []) {
        // Never a root or home folder by mistake.
        guard dir.path.count > 10, dir.path != NSHomeDirectory(),
              let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in items where !keeping.contains(item.lastPathComponent) { try? fm.removeItem(at: item) }
    }
}
