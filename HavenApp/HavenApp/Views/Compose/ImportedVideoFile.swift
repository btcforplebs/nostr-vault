import SwiftUI
import UniformTypeIdentifiers

/// Imports a PhotosPickerItem video as a file URL on disk, avoiding loading the
/// entire video into memory. The system writes the picked file into our app's
/// temp area; we copy it to a known location we can clean up later.
struct ImportedVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("haven-upload-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return ImportedVideoFile(url: dest)
        }
    }
}
