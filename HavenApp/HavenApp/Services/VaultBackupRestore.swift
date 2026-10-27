import Foundation

/// Restores a Nostr Vault backup file picked by the user into this device's
/// relay. Shared by setup's Import step and its "Do you have a Vault backup?"
/// question, so both run the same restore.
@MainActor
enum VaultBackupRestore {
    /// Copies the picked file out of its security scope, then restores it.
    /// `completion` gets nil on success, or the message to show.
    static func restore(from url: URL, configService: ConfigService,
                        completion: @escaping @MainActor (String?) -> Void) {
        guard url.startAccessingSecurityScopedResource() else {
            completion("Permission denied to access the file.")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?

        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { safeURL in
            do {
                if FileManager.default.fileExists(atPath: tempFile.path) {
                    try FileManager.default.removeItem(at: tempFile)
                }
                try FileManager.default.copyItem(at: safeURL, to: tempFile)
            } catch {
                copyError = error
            }
        }

        if let error = coordinationError ?? copyError {
            completion("Failed to copy backup file: \(error.localizedDescription)")
            return
        }

        configService.save()
        RelayProcessManager.shared.runBackupRestore(config: configService.config, inputPath: tempFile.path) { success in
            try? FileManager.default.removeItem(at: tempFile)
            Task { @MainActor in
                if success {
                    configService.reload()
                    completion(nil)
                } else {
                    completion("Failed to restore backup. Check logs for details.")
                }
            }
        }
    }
}
