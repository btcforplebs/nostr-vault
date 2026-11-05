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
        guard CopySettings.differs(config, from: readFile()?.keys) else { return }
        let keys = CopySettings.keys(config)
        // No file yet: nothing here has changed since a copy, so the first
        // file is dated oldest and any real change on a linked device wins.
        let at: Int64 = FileManager.default.fileExists(atPath: fileURL.path) ? Self.now : 1
        // Written only if it passes the same check the engine runs.
        guard let data = CopySettings.fileData(keys: keys, updatedAt: at),
              case .success = CopySettings.check(data, now: Self.now) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    /// Applies the file when it would change something here.
    func applyFromFile() {
        guard let checked = readFile() else { return }
        let config = ConfigService.shared.config
        guard CopySettings.differs(config, from: checked.keys) else { return }
        applying = true
        ConfigService.shared.config = CopySettings.apply(checked.keys, to: config)
        ConfigService.shared.save()
        // Past the debounce, so the write that the change triggers is skipped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.applying = false }
    }
}
