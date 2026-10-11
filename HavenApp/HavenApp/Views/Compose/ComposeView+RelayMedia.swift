import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
import AVFoundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

extension ComposeView {
    func loadBlossomMedia() {
        guard !isLoadingBlossomMedia else { return }
        guard relayManager.isRunning && !relayManager.isBooting else {
            blossomMedia = []
            return
        }
        isLoadingBlossomMedia = true
        Task {
            let result = await ComposeView.relayBlossomMedia(
                relayManager: relayManager, configService: configService, nostrService: nostrService)
            blossomMedia = result
            isLoadingBlossomMedia = false
        }
    }

    /// Everything in the relay's Blossom store, newest first, as the picker
    /// lists it. Shared by the composer and the live stream chat.
    static func relayBlossomMedia(relayManager: RelayProcessManager, configService: ConfigService,
                                  nostrService: NostrService) async -> [MediaItem] {
        let relayDataDir = configService.relayDataDir
        let blossomPath = configService.config.blossomPath
        let ownerHex = nostrService.activeHexPubkey
        let webURL = configService.config.webURL
        let rpm = relayManager
        // The Media tab dates a blob by the note that published it, not by the
        // file's mtime; without this the same photo sits under different
        // headings in the tab and here.
        var eventDates: [String: Date] = [:]
        for item in nostrService.noteMedia {
            guard let hash = ComposeView.blossomHash(in: item.url) else { continue }
            if let existing = eventDates[hash], existing >= item.dateAdded { continue }
            eventDates[hash] = item.dateAdded
        }
        let publishedDates = eventDates

        return await Task.detached(priority: .background) { () -> [MediaItem] in
            let blossomDir = relayDataDir.appendingPathComponent(blossomPath)
            guard FileManager.default.fileExists(atPath: blossomDir.path),
                  let fileURLs = try? FileManager.default.contentsOfDirectory(at: blossomDir, includingPropertiesForKeys: [.creationDateKey]) else {
                return []
            }
            return fileURLs.compactMap { fileURL -> MediaItem? in
                let filename = fileURL.lastPathComponent
                if filename.starts(with: ".") || filename == "LOCK" { return nil }
                guard let serveURL = URL(string: "\(webURL)/\(filename)") else { return nil }
                let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileDate = (attributes?[.modificationDate] as? Date) ?? (attributes?[.creationDate] as? Date) ?? Date()
                let date = ComposeView.blossomHash(in: fileURL).flatMap { publishedDates[$0] } ?? fileDate
                let proof = rpm.detectMimeFromBytes(for: fileURL)
                let resolvedMime = rpm.resolveMime(claim: nil, proof: proof)
                let mimeType = resolvedMime == "application/octet-stream" ? nil : resolvedMime
                let mediaType: MediaItem.MediaType
                if let mime = mimeType {
                    if mime.hasPrefix("video/") { mediaType = .video }
                    else if mime.hasPrefix("audio/") { mediaType = .audio }
                    else if mime.hasPrefix("image/") { mediaType = .image }
                    else { mediaType = .unknown }
                } else {
                    mediaType = .unknown
                }
                return MediaItem(id: UUID(), url: serveURL, type: mediaType, dateAdded: date, pubkey: ownerHex, tags: nil, mimeType: mimeType)
            }.sorted { $0.dateAdded > $1.dateAdded }
        }.value
    }
}
