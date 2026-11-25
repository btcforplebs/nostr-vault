import Foundation
import Combine

/// Keeps `copy-settings.json` in the relay root (contract §5) and this
/// app's config in step: the app writes the file whenever a listed setting
/// changes here, and applies it when the engine has left a newer one (the
/// first copy and every catch-up winner). Both directions run the same
/// refuse check as the engine. Android's twin is `CopySettingsSync.kt`.
@MainActor
final class CopySettingsSync {
    static let shared = CopySettingsSync()

    private var watcher: AnyCancellable?
    /// Set while applying, so the save that follows doesn't write a file back.
    private var applying = false
    /// The file as this app last wrote or read it. A file that differs was
    /// left by the engine (a merge can keep the newer side's date while
    /// changing the Vault list), so it is applied before anything is
    /// written: writing first would read its new Vaults as deleted here.
    private var lastSeen: Data?

    private var fileURL: URL {
        ConfigService.shared.relayDataDir.appendingPathComponent(CopySettings.fileName)
    }

    private static var now: Int64 { Int64(Date().timeIntervalSince1970) }

    func startWatching() {
        guard watcher == nil else { return }
        applyFromFile()
        watcher = ConfigService.shared.$config
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] config in self?.writeIfChanged(config) }
    }

    /// The file's checked keys, or nil (none yet, or refused).
    private func readFile() -> CopySettings.Checked? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        switch CopySettings.check(data, now: Self.now) {
        case .success(let checked): return checked
        case .failure(let e):
            RelayProcessManager.shared.addLog("Copied settings not used: \(e.reason.rawValue)", level: "ERROR")
            return nil
        }
    }

    private func writeIfChanged(_ config: HavenConfig) {
        guard !applying, config.hasCompletedSetup else { return }
        if let lastSeen, let now = try? Data(contentsOf: fileURL), now != lastSeen {
            takeInForeign(previous: lastSeen, config: config)
            return
        }
        guard CopySettings.differs(config, from: readFile()?.keys) else { return }
        write(config)
    }

    /// A file the engine left (a peer's PUT, a catch-up) found when a setting
    /// changed here. With no edit here since `previous`, it is applied as
    /// usual. With one, only what the other device changed since `previous`
    /// is taken in and then this device's edit is written over it, so the
    /// newest change wins on each key and the edit isn't reverted (Tron on #2521).
    private func takeInForeign(previous: Data, config: HavenConfig) {
        guard case .success(let before) = CopySettings.check(previous, now: Self.now),
              CopySettings.differs(config, from: before.keys) else { return applyFromFile() }
        lastSeen = try? Data(contentsOf: fileURL)
        guard let checked = readFile() else { return write(config) }
        let next = CopySettings.apply(CopySettings.changedKeys(checked.keys, since: before.keys), to: config)
        if CopySettings.differs(config, from: CopySettings.keys(next, previousVaults: checked.keys["desktop_vaults"] as? [Any])) {
            applying = true
            ConfigService.shared.config = next
            ConfigService.shared.save()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.applying = false }
        }
        if CopySettings.differs(next, from: checked.keys) { write(next) }
    }

    private func write(_ config: HavenConfig) {
        let keys = CopySettings.keys(config, previousVaults: readFile()?.keys["desktop_vaults"] as? [Any])
        // No file yet: nothing here has changed since a copy, so the first
        // file is dated oldest and any real change on a linked device wins.
        let at: Int64 = FileManager.default.fileExists(atPath: fileURL.path) ? Self.now : 1
        // Written only if it passes the same check the engine runs.
        guard let data = CopySettings.fileData(keys: keys, updatedAt: at),
              case .success = CopySettings.check(data, now: Self.now) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        lastSeen = data
    }

    /// Applies the file when it would change something here.
    func applyFromFile() {
        lastSeen = try? Data(contentsOf: fileURL)
        guard let checked = readFile() else { return }
        let config = ConfigService.shared.config
        // A file with the retired "condensed" layout reads as expanded, so
        // nothing differs, but it is written over now, clean, so it stops
        // reaching linked devices (11/14).
        if CopySettings.holdsRetiredLayout(checked.keys), config.hasCompletedSetup {
            write(CopySettings.differs(config, from: checked.keys) ? CopySettings.apply(checked.keys, to: config) : config)
        }
        guard CopySettings.differs(config, from: checked.keys) else { return }
        applying = true
        ConfigService.shared.config = CopySettings.apply(checked.keys, to: config)
        ConfigService.shared.save()
        // Past the debounce, so the write that the change triggers is skipped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.applying = false }
    }
}
