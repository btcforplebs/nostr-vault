import SwiftUI
import UniformTypeIdentifiers

/// When the vault last did the things that keep it complete and safe. The
/// Vault Dashboard shows these as "last ran" lines; nothing else stored them.
/// Device-wide: there is one vault per device, whichever account is active.
enum VaultHistory {
    private static let defaults = UserDefaults.standard
    private static let notesImportKey = "haven.vault.lastNotesImport"
    private static let notesBackupKey = "haven.vault.lastNotesBackup"
    private static let mediaBackupKey = "haven.vault.lastMediaBackup"
    private static let mediaImportKey = "haven.vault.lastMediaImport"

    static var lastNotesImport: Date? {
        get { defaults.object(forKey: notesImportKey) as? Date }
        set { defaults.set(newValue, forKey: notesImportKey) }
    }

    /// The last JSONL backup file made, from the dashboard or Settings › Backup.
    static var lastNotesBackup: Date? {
        get { defaults.object(forKey: notesBackupKey) as? Date }
        set { defaults.set(newValue, forKey: notesBackupKey) }
    }

    static var lastMediaBackup: Date? {
        get { defaults.object(forKey: mediaBackupKey) as? Date }
        set { defaults.set(newValue, forKey: mediaBackupKey) }
    }

    static var lastMediaImport: Date? {
        get { defaults.object(forKey: mediaImportKey) as? Date }
        set { defaults.set(newValue, forKey: mediaImportKey) }
    }
}

/// Makes the two backup files, notes (JSONL) and media (Blossom), and hands
/// them to a save panel on macOS or the share sheet on iOS. Shared by the
/// Vault Dashboard and the relay dashboard so both record the backup time.
@MainActor
final class VaultExporter: ObservableObject {
    enum Kind {
        case notes, media

        var noun: String { self == .notes ? "Notes" : "Media" }
        var fileStem: String { self == .notes ? "haven-backup" : "blossom-backup" }
        var panelTitle: String { self == .notes ? "Save JSONL Backup" : "Save Blossom Backup" }
    }

    @Published private(set) var running: Kind?
    @Published private(set) var statusMessage = ""
    @Published private(set) var statusIsError = false
    @Published var shareURL: URL?

    var isBusy: Bool { running != nil }

    func export(_ kind: Kind, relayManager: RelayProcessManager, config: HavenConfig) {
        guard running == nil else { return }
        running = kind
        setStatus("Preparing \(kind.noun.lowercased()) backup…")

        let tempPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(kind.fileStem)-\(Date().timeIntervalSince1970).zip")
        let finish: @Sendable (Bool) -> Void = { [weak self] success in
            Task { @MainActor in self?.finish(kind, success: success, tempPath: tempPath) }
        }
        switch kind {
        case .notes:
            relayManager.runBackupExport(config: config, outputPath: tempPath, completion: finish)
        case .media:
            relayManager.runBlossomExportWithExtensions(config: config, outputPath: tempPath, completion: finish)
        }
    }

    private func finish(_ kind: Kind, success: Bool, tempPath: String) {
        running = nil
        guard success else {
            setStatus("\(kind.noun) backup failed", isError: true)
            clearStatusLater()
            return
        }
        switch kind {
        case .notes: VaultHistory.lastNotesBackup = Date()
        case .media: VaultHistory.lastMediaBackup = Date()
        }

        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = kind.panelTitle
        panel.nameFieldStringValue = "\(kind.fileStem).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let destURL = panel.url {
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: URL(fileURLWithPath: tempPath), to: destURL)
                setStatus("Saved to \(destURL.lastPathComponent)")
            } catch {
                setStatus("Failed to save: \(error.localizedDescription)", isError: true)
            }
        } else {
            setStatus("Export cancelled")
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        clearStatusLater()
        #else
        shareURL = URL(fileURLWithPath: tempPath)
        setStatus("Ready to share")
        #endif
    }

    private func setStatus(_ message: String, isError: Bool = false) {
        withAnimation(Motion.fade) {
            statusMessage = message
            statusIsError = isError
        }
    }

    private func clearStatusLater() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.setStatus("")
        }
    }
}
