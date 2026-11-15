import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A video picked or dropped for the next DM: a copy in the temporary
/// directory (the thread deletes it once sent or removed), its type, and a
/// still for the preview. It goes up through the same upload as a post's
/// video (ModePostPublisher.upload(fileURL:)) and its link is sent in the
/// message, as a photo's is (DMAttachment).
struct DMVideoAttachment {
    let file: URL
    let type: UTType

    var mimeType: String { type.preferredMIMEType ?? "video/mp4" }
    var fileExtension: String { file.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "mp4") : file.pathExtension }

    static func isVideo(_ item: PhotosPickerItem) -> Bool {
        item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
    }

    /// Copies the picked video to disk without loading it into memory.
    static func load(_ item: PhotosPickerItem) async -> DMVideoAttachment? {
        guard let video = try? await item.loadTransferable(type: ImportedVideoFile.self) else { return nil }
        return DMVideoAttachment(file: video.url, type: UTType(filenameExtension: video.url.pathExtension) ?? .mpeg4Movie)
    }

    /// The first frame, for the preview above the message box.
    func poster() async -> Image? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        guard let frame = try? await generator.image(at: .zero).image else { return nil }
        #if canImport(UIKit)
        return Image(uiImage: UIImage(cgImage: frame))
        #else
        return Image(nsImage: NSImage(cgImage: frame, size: .zero))
        #endif
    }

    func discard() {
        try? FileManager.default.removeItem(at: file)
    }
}

/// A video a message carries: a frame from the clip with a play button;
/// tapping it opens the media viewer, which plays it.
struct DMVideoTile: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        // The same frame-grab the Media page's tiles use (cached), so a clip
        // in a chat looks like what it is instead of a black square.
        VideoThumbnailView(url: url)
            .frame(width: size, height: size)
            .clipped()
        .contentShape(Rectangle())
        .accessibilityLabel("Video")
    }
}
