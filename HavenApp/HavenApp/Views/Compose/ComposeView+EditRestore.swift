import SwiftUI
import UniformTypeIdentifiers

/// Edit on a pending post: its hosted photos come back as attachments, not as
/// bare links in the text (PendingPostEdit). Each link stays where it was in
/// the text; the attachment is marked hosted by the upload path for media
/// that is already on a server, which uploads nothing.
extension ComposeView {
    func restoreEditedMedia(_ media: [PendingPostEdit.Media]) {
        for item in media {
            guard attachments.count < Self.maxAttachments, let url = URL(string: item.url),
                  !attachments.contains(where: { $0.url?.absoluteString == item.url }) else { continue }
            let type = item.mimeType.flatMap { UTType(mimeType: $0) } ?? .image
            var attachment = Attachment(data: nil, fileURL: nil, type: type, url: url, isUploaded: true)
            attachment.altText = item.alt ?? ""
            // Read for imeta dimensions and size when this device's relay has the blob.
            let blob = configService.relayDataDir
                .appendingPathComponent(configService.config.blossomPath)
                .appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: blob.path) { attachment.relayBlobFile = blob }
            attachments.append(attachment)
            startUpload(for: attachment.id)
        }
    }
}
