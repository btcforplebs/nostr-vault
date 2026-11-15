import Foundation

/// What the viewer's Copy puts on the clipboard: the photo or clip itself,
/// in its own format, so pasting into Messages or Notes gives the media and
/// not a link. Read from the file's first bytes, because Blossom URLs are a
/// bare hash with no extension.
enum MediaClipboard {
    enum Format: Equatable {
        case gif, png, jpeg, heic, webp, mp4, mov
        /// Unknown bytes: a photo is re-drawn as PNG, a clip is not copied.
        case other
    }

    static func format(of header: Data) -> Format {
        let b = [UInt8](header.prefix(16))
        func ascii(_ range: Range<Int>) -> String? {
            guard b.count >= range.upperBound else { return nil }
            return String(bytes: b[range], encoding: .ascii)
        }
        if ascii(0..<4) == "GIF8" { return .gif }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "WEBP" { return .webp }
        if ascii(4..<8) == "ftyp", let brand = ascii(8..<12) {
            switch brand {
            case "heic", "heix", "hevc", "heim", "heis", "mif1", "msf1": return .heic
            case "qt  ": return .mov
            default: return .mp4
            }
        }
        return .other
    }

    /// The pasteboard type the bytes go under, or nil when a photo must be
    /// re-drawn as PNG first (WebP and unknown: most apps will not paste them).
    static func pasteboardType(for format: Format) -> String? {
        switch format {
        case .gif: return "com.compuserve.gif"
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        case .mp4: return "public.mpeg-4"
        case .mov: return "com.apple.quicktime-movie"
        case .webp, .other: return nil
        }
    }

    /// File extension for a copied or shared file, so the receiving app
    /// knows what it got. A photo that is re-drawn becomes a PNG.
    static func fileExtension(for format: Format, isClip: Bool) -> String {
        switch format {
        case .gif: return "gif"
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .mp4: return "mp4"
        case .mov: return "mov"
        case .webp, .other: return isClip ? "mp4" : "png"
        }
    }
}
