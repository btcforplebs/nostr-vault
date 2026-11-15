import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Gets the photo or clip the viewer shows into a file, for Copy and Share.
/// The file keeps its own format (`MediaClipboard`), so a GIF stays a GIF.
@MainActor
enum ViewerMediaTransfer {
    struct Prepared {
        let file: URL
        let format: MediaClipboard.Format
    }

    enum Failure: LocalizedError {
        case http(Int), unreadable
        var errorDescription: String? {
            switch self {
            case .http(let code): return "Couldn't download the media (HTTP \(code))"
            case .unreadable: return "Couldn't read this media"
            }
        }
    }

    /// One folder, emptied on every Copy or Share: the clipboard and the share
    /// sheet read the last file lazily, so it must outlive the call.
    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ViewerMedia", isDirectory: true)
    }

    /// Downloads `url` (clips straight to disk, never whole into memory) and
    /// names the file after what its bytes are.
    static func prepare(_ url: URL, isClip: Bool) async throws -> Prepared {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appendingPathComponent(UUID().uuidString)

        if url.isFileURL {
            try fm.copyItem(at: url, to: staged)
        } else if !isClip, let cached = await MediaCacheService.shared.fetchData(url: url) {
            try cached.write(to: staged)
        } else {
            let session = URLSession(configuration: .default, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let (downloaded, response) = try await session.download(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw Failure.http(http.statusCode)
            }
            try fm.moveItem(at: downloaded, to: staged)
        }

        let handle = try FileHandle(forReadingFrom: staged)
        let header = (try? handle.read(upToCount: 16)) ?? Data()
        try? handle.close()
        let format = MediaClipboard.format(of: header)
        let named = folder.appendingPathComponent("media." + MediaClipboard.fileExtension(for: format, isClip: isClip))
        try fm.moveItem(at: staged, to: named)
        return Prepared(file: named, format: format)
    }

    /// Puts the media itself on the clipboard. A photo whose format other
    /// apps will not paste (WebP) is re-drawn as PNG.
    static func copy(_ media: Prepared, isClip: Bool) throws {
        #if os(iOS)
        if isClip {
            guard let provider = NSItemProvider(contentsOf: media.file) else { throw Failure.unreadable }
            UIPasteboard.general.setItemProviders([provider], localOnly: false, expirationDate: nil)
            return
        }
        let data = try Data(contentsOf: media.file)
        if let type = MediaClipboard.pasteboardType(for: media.format) {
            UIPasteboard.general.setItems([[type: data]])
        } else if let png = UIImage(data: data)?.pngData() {
            UIPasteboard.general.setItems([["public.png": png]])
        } else {
            throw Failure.unreadable
        }
        #else
        let board = NSPasteboard.general
        board.clearContents()
        if isClip {
            board.writeObjects([media.file as NSURL])
            return
        }
        let data = try Data(contentsOf: media.file)
        if let type = MediaClipboard.pasteboardType(for: media.format) {
            board.setData(data, forType: NSPasteboard.PasteboardType(type))
        } else if let image = NSImage(data: data) {
            board.writeObjects([image])
        } else {
            throw Failure.unreadable
        }
        #endif
    }
}

/// A file handed to the share sheet.
struct ViewerShareFile: Identifiable {
    let id = UUID()
    let url: URL
}
