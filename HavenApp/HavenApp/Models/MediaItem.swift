import Foundation

struct MediaItem: Identifiable, Codable, Hashable, Equatable {
    let id: UUID
    let url: URL
    let type: MediaType
    let dateAdded: Date
    let pubkey: String? // Author of the event containing this media
    let tags: [[String]]? // Tags of the event containing this media
    let mimeType: String?
    /// Bytes, when a local source knows it (A1): this device's file, or the
    /// file note's `size`. nil is unknown, never empty. See `knownSize`.
    var size: Int64? = nil

    enum MediaType: String, Codable, Hashable, Equatable {
        case image
        case video
        case audio
        case unknown
    }

    /// True if this item is a GIF — checked via mime type first (works for
    /// extensionless blossom URLs), then URL extension as a fallback.
    var isAnimatedGIF: Bool {
        if mimeType?.lowercased() == "image/gif" { return true }
        return url.pathExtension.lowercased() == "gif"
    }
}

extension MediaItem {
    @MainActor
    func shareURL(with configService: ConfigService) -> URL {
        let baseSharedURL = configService.externalShareURL(for: url)
        
        guard baseSharedURL.pathExtension.isEmpty else {
            return baseSharedURL
        }
        
        var ext: String? = nil
        if let mime = mimeType?.lowercased() {
            ext = SupportedMediaFormats.extension(forMime: mime)
            // Fallback: strip prefix for unknown subtypes
            if ext == nil {
                if mime.hasPrefix("image/") { ext = String(mime.dropFirst(6)) }
                else if mime.hasPrefix("video/") { ext = String(mime.dropFirst(6)) }
                else if mime.hasPrefix("audio/") { ext = String(mime.dropFirst(6)) }
            }
        }
        
        if ext == nil {
            switch type {
            case .video:
                ext = "mp4"
            case .image:
                ext = isAnimatedGIF ? "gif" : "jpg"
            case .audio:
                ext = "mp3"
            case .unknown:
                break
            }
        }
        
        if let extensionToAppend = ext {
            return baseSharedURL.appendingPathExtension(extensionToAppend)
        }
        
        return baseSharedURL
    }
}

extension UUID {
    static func deterministic(from string: String) -> UUID {
        let hash = string.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ UInt32($1) }
        let hash2 = string.utf8.reduce(1234) { ($0 << 3) &+ $0 &+ UInt32($1) }
        let hash3 = string.utf8.reduce(9876) { ($0 << 7) &+ $0 &+ UInt32($1) }
        let hash4 = string.utf8.reduce(4321) { ($0 << 4) &+ $0 &+ UInt32($1) }
        
        let hex1 = String(format: "%08x", hash)
        let hex2 = String(format: "%04x", hash2 & 0xFFFF)
        let hex3 = String(format: "%04x", (hash3 & 0x0FFF) | 0x4000)
        let hex4 = String(format: "%04x", (hash4 & 0x3FFF) | 0x8000)
        let hex5 = String(format: "%012x", UInt64(hash) << 16 | UInt64(hash2))
        
        let uuidStr = "\(hex1)-\(hex2)-\(hex3)-\(hex4)-\(hex5)"
        return UUID(uuidString: uuidStr) ?? UUID()
    }
}


