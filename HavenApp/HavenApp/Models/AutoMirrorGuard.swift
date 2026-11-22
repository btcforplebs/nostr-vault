import Foundation
import UniformTypeIdentifiers

/// The checks the Linux box's Auto-Mirror makes on every file it downloads
/// (haven-go/auto_mirror.go `fetchIntoVault`), now made on the Mac too
/// (dashboard parity report §4, 2026-11-22). Before this the Mac stored any
/// link a note named, of any type and size, without checking the bytes were
/// the file the note said.
enum AutoMirrorGuard {
    /// The most one file may be: haven-go's `maxBlobBytes` (blob_spool.go).
    static let maxFileBytes: Int64 = 256 << 20

    /// Types a browser runs as a page or script: haven-go's `activeBlobTypes`
    /// (jsonl.go). The vault serves a blob with the type it was stored with,
    /// so one of these would turn a "photo" into a page on the vault's host.
    static let activeTypes: Set<String> = [
        "text/html", "application/xhtml+xml", "image/svg+xml",
        "text/javascript", "application/javascript", "text/xml", "application/xml",
    ]

    /// The type the server sent, else the one the link's extension names (as
    /// the box does), lower-cased with parameters dropped. Nil when neither says.
    static func mediaType(declared: String?, url: URL?) -> String? {
        let sent = declared?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if let sent, !sent.isEmpty { return sent }
        guard let ext = url?.pathExtension, !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.preferredMIMEType?.lowercased()
    }

    /// Whether a file of this type may go into the vault: any plain
    /// type/subtype except the active ones. No type at all is allowed (it is
    /// stored as application/octet-stream), as on the box.
    static func allowsType(declared: String?, url: URL?) -> Bool {
        guard let type = mediaType(declared: declared, url: url) else { return true }
        return type.contains("/") && !activeTypes.contains(type)
    }

    /// `allowsType` as StreamingBlobDownload asks it (sent type, link).
    static let typeCheck: @Sendable (String?, URL?) -> Bool = { allowsType(declared: $0, url: $1) }

    /// The limits Auto-Mirror passes to a download; nil limits for any other.
    static func limits(autoMirror: Bool) -> (maxBytes: Int64?, allowsType: (@Sendable (String?, URL?) -> Bool)?) {
        autoMirror ? (maxFileBytes, typeCheck) : (nil, nil)
    }

    /// The hash a note link must arrive as, when anything names it: the
    /// link's own name (a Blossom link is named by its hash), else the note's
    /// imeta `x`. The box checks the same two, in this order. Nil: nothing
    /// says, so the file is stored under whatever hash it has.
    static func expectedHash(for url: URL, imeta: [String: String]) -> String? {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        if AutoMirrorLedger.isHash(name) { return name }
        return imeta[url.absoluteString]
    }
}
