import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The bytes a DM photo is locked and sent as, by Settings › Upload Quality
/// (plan A4). Standard is what DMs always sent: an upright JPEG, long edge at
/// most 2400 px, with no metadata. Original sends the photo at full size (a
/// HEIC becomes a JPEG, as `ImageCompressor` does for the Media tab) with
/// only the location taken out (`MediaPrivacy`). GIFs are handled before this.
enum DMPhotoQuality {
    static func prepared(_ data: Data, quality: ImageCompressor.Quality) -> (data: Data, mimeType: String)? {
        switch quality {
        case .standard:
            return LongFormComposeView.coverJPEG(from: data).map { ($0, "image/jpeg") }
        case .original:
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let raw = CGImageSourceGetType(source),
                  let type = UTType(raw as String), type.conforms(to: .image),
                  CGImageSourceGetCount(source) > 0
            else { return nil }
            let photo = ImageCompressor.prepare(data, type: type, quality: .original)
            guard let clean = MediaPrivacy.removingLocation(fromImageData: photo.data) else { return nil }
            return (clean, photo.mimeType)
        }
    }
}
