import SwiftUI
import UniformTypeIdentifiers

struct BackupSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager

    enum ImportType {
        case jsonl
        case blossom
    }

    @State private var isExportingJSONL = false
    @State private var isImportingJSONL = false
    @State private var isImportingBlossom = false
    @State private var statusMessage = ""
    /// A refused restore ("This backup isn't…") is a failure too.
    private var statusFailed: Bool {
        statusMessage.contains("failed") || statusMessage.contains("Failed") || statusMessage.contains("Error")
            || statusMessage.contains("This backup isn't")
    }
    @State private var activeImportType: ImportType?
    @State private var showFileImporter = false
    
    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Export Notes")
                            .font(.appBody)
                        Text("Save all notes and metadata as a JSONL backup")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: exportJSONL) {
                        HStack(spacing: 6) {
                            if isExportingJSONL {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.up.doc.fill")
                            }
                            Text("Export")
                        }
                    }
                    .disabled(isExportingJSONL || isImportingJSONL || isImportingBlossom)
                }
                
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Import Notes")
                            .font(.appBody)
                        Text("Restore notes from a Nostr Vault JSONL backup (.zip)")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: importJSONL) {
                        HStack(spacing: 6) {
                            if isImportingJSONL {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.doc.fill")
                            }
                            Text("Import")
                        }
                    }
                    .disabled(isExportingJSONL || isImportingJSONL || isImportingBlossom)
                }
            } header: {
                Text("Notes").settingInfo(.relayBackup)
            }
            
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Import Media")
                            .font(.appBody)
                        Text("Restore media from a media backup (.zip)")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: importBlossom) {
                        HStack(spacing: 6) {
                            if isImportingBlossom {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "photo.badge.arrow.down")
                            }
                            Text("Import")
                        }
                    }
                    .disabled(isExportingJSONL || isImportingJSONL || isImportingBlossom)
                }
            } header: {
                Text("Media")
            } footer: {
                // One button backs up media: the dashboard's (2026-11-12).
                Text("To back up your media, use Back up media on the dashboard.")
            }

            if !statusMessage.isEmpty {
                Section {
                    HStack {
                        Image(systemName: statusFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundColor(statusFailed ? .red : .havenOnline)
                        Text(statusMessage)
                            .font(.appCallout)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            switch activeImportType {
            case .jsonl:
                handleJSONLImport(result)
            case .blossom:
                handleBlossomImport(result)
            case .none:
                break
            }
        }
        #endif
    }
    
    // MARK: - JSONL Export
    
    private func exportJSONL() {
        isExportingJSONL = true
        statusMessage = "Preparing JSONL export..."
        
        let tempDir = NSTemporaryDirectory()
        let tempPath = (tempDir as NSString).appendingPathComponent("nostrvault-backup-\(Date().timeIntervalSince1970).zip")
        
        relayManager.runBackupExport(config: configService.config, outputPath: tempPath) { success in
            Task { @MainActor in
                isExportingJSONL = false
                guard success else {
                    statusMessage = "JSONL export failed"
                    clearStatus()
                    return
                }
                // "Last backup" only once the file is really saved or shared, not on a cancel.
                #if os(macOS)
                presentSavePanel(title: "Save JSONL Backup", defaultName: "nostrvault-backup.zip", tempPath: tempPath) { VaultHistory.lastNotesBackup = Date() }
                #else
                shareFile(at: tempPath) { VaultHistory.lastNotesBackup = Date() }
                statusMessage = ""
                #endif
            }
        }
    }
    
    // MARK: - JSONL Import
    
    private func importJSONL() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose JSONL Backup"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        performJSONLRestore(from: url)
        #else
        activeImportType = .jsonl
        showFileImporter = true
        #endif
    }
    
    #if os(iOS)
    private func handleJSONLImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            performJSONLRestore(from: url)
        case .failure(let error):
            statusMessage = "Import error: \(error.localizedDescription)"
            clearStatus()
        }
    }
    #endif
    
    private func performJSONLRestore(from url: URL) {
        isImportingJSONL = true
        statusMessage = "Restoring notes..."
        
        // Read where it is, no temp copy (#17).
        ScopedImportFile.read(url) { path, finished in
            // Only this vault owner's own backup: someone else's is never merged in.
            relayManager.runOwnBackupRestore(config: configService.config, inputPath: path) { code in
                finished()
                Task { @MainActor in
                    isImportingJSONL = false
                    // Checked against this vault's owner, not the active account.
                    statusMessage = BackupRestoreCode.error(code: code) ?? "Notes restored successfully!"
                    clearStatus()
                }
            }
        }
    }
    
    // MARK: - Blossom Import
    
    private func importBlossom() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose Media Backup"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        performBlossomRestore(from: url)
        #else
        activeImportType = .blossom
        showFileImporter = true
        #endif
    }
    
    #if os(iOS)
    private func handleBlossomImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            performBlossomRestore(from: url)
        case .failure(let error):
            statusMessage = "Import error: \(error.localizedDescription)"
            clearStatus()
        }
    }
    #endif
    
    private func performBlossomRestore(from url: URL) {
        isImportingBlossom = true
        statusMessage = "Restoring media..."
        
        // Read where it is, no temp copy (#17).
        ScopedImportFile.read(url) { path, finished in
            relayManager.runBlossomImportStrippingExtensions(config: configService.config, inputPath: path) { success in
                finished()
                Task { @MainActor in
                    isImportingBlossom = false
                    statusMessage = success ? "Media restored successfully!" : "Media restore failed. No vault media found in that file."
                    clearStatus()
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    #if os(macOS)
    private func presentSavePanel(title: String, defaultName: String, tempPath: String, onSaved: () -> Void) {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK, let destURL = panel.url {
            let srcURL = URL(fileURLWithPath: tempPath)
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: srcURL, to: destURL)
                onSaved()
                statusMessage = "Saved to \(destURL.lastPathComponent)"
            } catch {
                statusMessage = "Failed to save: \(error.localizedDescription)"
            }
        } else {
            statusMessage = "Export cancelled"
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        clearStatus()
    }
    #endif
    
    #if os(iOS)
    private func shareFile(at path: String, onShared: @escaping () -> Void) {
        let fileURL = URL(fileURLWithPath: path)
        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        activityVC.completionWithItemsHandler = { _, completed, _, error in
            if completed && error == nil { onShared() }
        }
        
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first,
              var top = window.rootViewController else { return }
        // Settings is itself a sheet: the root is already presenting, so it
        // would refuse the share sheet. Present from whatever is on top.
        while let presented = top.presentedViewController { top = presented }
        // iPad shows the share sheet as a popover, which needs an anchor.
        activityVC.popoverPresentationController?.sourceView = top.view
        activityVC.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        activityVC.popoverPresentationController?.permittedArrowDirections = []
        top.present(activityVC, animated: true)
    }
    #endif
    
    private func clearStatus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            statusMessage = ""
        }
    }

}
