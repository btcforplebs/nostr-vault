import Foundation

/// A received file that is not a photo or video (a PDF from the web or
/// Android, say): what the bubble calls it, its symbol, and the extension
/// its opened copy needs so Quick Look can show it (B11, 2026-11-19).
enum DMFileKind {
    static func label(_ mime: String) -> String {
        switch mime.lowercased() {
        case "application/pdf": return "PDF document"
        case "application/zip", "application/x-zip-compressed": return "ZIP archive"
        case let m where m.hasPrefix("audio/"): return "Audio file"
        case let m where m.hasPrefix("text/"): return "Text file"
        default: return "File"
        }
    }

    static func symbol(_ mime: String) -> String {
        switch mime.lowercased() {
        case "application/pdf": return "doc.richtext.fill"
        case "application/zip", "application/x-zip-compressed": return "doc.zipper"
        case let m where m.hasPrefix("audio/"): return "waveform"
        case let m where m.hasPrefix("text/"): return "doc.text.fill"
        default: return "doc.fill"
        }
    }

    /// Nil for a type with no known extension (the copy keeps "bin").
    static func fileExtension(_ mime: String) -> String? {
        switch mime.lowercased() {
        case "application/pdf": return "pdf"
        // An archive stays "bin" (DMFileTests): Quick Look still names it.
        case "text/plain": return "txt"
        case "text/markdown": return "md"
        case "text/csv": return "csv"
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/aac": return "m4a"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/ogg": return "ogg"
        default: return nil
        }
    }
}
