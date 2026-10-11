import Foundation
@preconcurrency import Dispatch
import Combine
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

extension RelayProcessManager {
    // MARK: - Blossom Backup
    
    // MARK: - Blossom Extensions Logic
    
    func runBlossomExportWithExtensions(config: HavenConfig, outputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        guard isRunning else {
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Cannot export: relay must be running to detect file types."))
            completion(false)
            return
        }

        let blossomDir = ConfigService.shared.relayDataDir.appendingPathComponent(config.blossomPath)

        guard FileManager.default.fileExists(atPath: blossomDir.path) else {
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Blossom directory not found: \(blossomDir.path)"))
            completion(false)
            return
        }
        
        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Starting Blossom export with extensions..."))
        
        // Create temp dir for staging files with extensions
        let tempDir = FileManager.default.temporaryDirectory
        let stagingDir = tempDir.appendingPathComponent("BlossomExport_\(UUID().uuidString)")
        let tempZipURL = tempDir.appendingPathComponent("blossom_export_temp_\(UUID().uuidString).zip")
        
        Task.detached {
            do {
                try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                
                // Iterate files in blossomDir
                let fileURLs = try FileManager.default.contentsOfDirectory(at: blossomDir, includingPropertiesForKeys: nil)
                
                for fileURL in fileURLs {
                    // Ignore hidden files
                    if fileURL.lastPathComponent.hasPrefix(".") { continue }

                    let sha256 = fileURL.lastPathComponent
                    let proof = self.detectMimeFromBytes(for: fileURL)
                    
                    let claim: String?
                    // Only perform the network check if magic bytes are inconclusive
                    if proof == "application/octet-stream" {
                        claim = await self.fetchMimeFromRelay(config: config, sha256: sha256)
                    } else {
                        claim = nil
                    }
                    
                    let resolvedMime = self.resolveMime(claim: claim, proof: proof)
                    let ext = self.mimeToExtension(resolvedMime)

                    let newFilename = sha256 + (ext == "bin" ? "" : ".\(ext)")
                    let destURL = stagingDir.appendingPathComponent(newFilename)

                    try FileManager.default.copyItem(at: fileURL, to: destURL)
                }
                
                // Zip the staging directory content using Go ZipDirectoryC
                guard let cSrc = strdup(stagingDir.path), let cDst = strdup(tempZipURL.path) else {
                    await MainActor.run {
                        try? FileManager.default.removeItem(at: stagingDir)
                        self.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Memory allocation failed for Blossom export"))
                        completion(false)
                    }
                    return
                }
                let result = ZipDirectoryC(cSrc, cDst)
                free(cSrc)
                free(cDst)
                
                await MainActor.run {
                    // Cleanup staging
                    try? FileManager.default.removeItem(at: stagingDir)
                    
                    if result == 0 {
                        // Move zip to final destination
                        do {
                            let destURL = URL(fileURLWithPath: outputPath)
                            if FileManager.default.fileExists(atPath: destURL.path) {
                                try FileManager.default.removeItem(at: destURL)
                            }
                            try FileManager.default.moveItem(at: tempZipURL, to: destURL)
                            self.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Blossom export saved to \(outputPath)"))
                            completion(true)
                        } catch {
                            self.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to move export to destination: \(error.localizedDescription)"))
                            try? FileManager.default.removeItem(at: tempZipURL)
                            completion(false)
                        }
                    } else {
                        self.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Blossom export failed in Go process"))
                        try? FileManager.default.removeItem(at: tempZipURL)
                        completion(false)
                    }
                }
            } catch {
                await MainActor.run {
                    self.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to prepare Blossom export: \(error.localizedDescription)"))
                    try? FileManager.default.removeItem(at: stagingDir)
                    completion(false)
                }
            }
        }
    }
    
    func runBlossomImportStrippingExtensions(config: HavenConfig, inputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        let blossomDir = ConfigService.shared.relayDataDir.appendingPathComponent(config.blossomPath)
        
        // Ensure blossom directory exists
        try? FileManager.default.createDirectory(at: blossomDir, withIntermediateDirectories: true)
        
        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Starting Blossom import (stripping extensions)..."))
        
        // 1. Copy input zip to temp
        let tempDir = FileManager.default.temporaryDirectory
        let tempZipURL = tempDir.appendingPathComponent("blossom_import_source_\(UUID().uuidString).zip")
        let stagingDir = tempDir.appendingPathComponent("BlossomImport_\(UUID().uuidString)")
        
        do {
            if FileManager.default.fileExists(atPath: tempZipURL.path) {
                try FileManager.default.removeItem(at: tempZipURL)
            }
            try FileManager.default.copyItem(atPath: inputPath, toPath: tempZipURL.path)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to setup temp dirs: \(error)"))
            completion(false)
            return
        }
        
        // 2. Unzip to staging using Go UnzipDirectoryC
        DispatchQueue.global().async { [weak self] in
            guard let cSrc = strdup(tempZipURL.path), let cDst = strdup(stagingDir.path) else {
                Task { @MainActor in
                    self?.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Memory allocation failed for Blossom import"))
                    try? FileManager.default.removeItem(at: tempZipURL)
                    completion(false)
                }
                return
            }
            let result = UnzipDirectoryC(cSrc, cDst)
            free(cSrc)
            free(cDst)
            
            Task { @MainActor in
                // Cleanup zip copy
                try? FileManager.default.removeItem(at: tempZipURL)
                
                if result == 0 {
                    // 3. Process files in staging
                    do {
                        let fileURLs = try FileManager.default.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)
                        var count = 0
                        
                        for fileURL in fileURLs {
                            if fileURL.hasDirectoryPath { continue }
                            if fileURL.lastPathComponent.hasPrefix(".") { continue }
                            if fileURL.lastPathComponent == "__MACOSX" { continue }
                            
                            // Strip extension
                            let filename = fileURL.deletingPathExtension().lastPathComponent
                            
                            // Validate SHA256 (64 hex chars)
                            if filename.count == 64 && filename.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil {
                                let destURL = blossomDir.appendingPathComponent(filename)
                                // Overwrite
                                if FileManager.default.fileExists(atPath: destURL.path) {
                                    try FileManager.default.removeItem(at: destURL)
                                }
                                try FileManager.default.moveItem(at: fileURL, to: destURL)
                                count += 1
                            } else {
                                self?.logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Skipping invalid blossom file: \(fileURL.lastPathComponent)"))
                            }
                        }
                        
                        self?.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Blossom import complete. Imported \(count) files."))
                        try? FileManager.default.removeItem(at: stagingDir)
                        completion(true)
                        
                    } catch {
                         self?.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Error processing imported files: \(error)"))
                         try? FileManager.default.removeItem(at: stagingDir)
                         completion(false)
                    }
                } else {
                    self?.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Unzip failed in Go process"))
                    try? FileManager.default.removeItem(at: stagingDir)
                    completion(false)
                }
            }
        }
    }
}
