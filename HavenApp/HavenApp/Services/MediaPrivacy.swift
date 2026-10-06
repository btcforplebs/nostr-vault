import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Media Privacy
//
// Removes where a photo or video was taken before it is uploaded. A Blossom
// blob is public and content-addressed: once a mirror has it, a GPS fix in it
// cannot be taken back.
//
// Only files that actually carry a location are rewritten, so a GIF keeps its
// animation and an ordinary photo uploads byte for byte. When a location is
// found and cannot be removed, the caller gets nil and must not upload: the
// rule is "never send a location", not "try to".

enum MediaPrivacy {

    /// Shown when a file has a location that could not be removed.
    static let failureMessage = "Couldn't remove the location from this file, so it wasn't uploaded."

    /// The file to upload in place of `url`: `url` itself when it carries no
    /// location (or is not media), a new temporary file when one was removed,
    /// nil when a location is there and could not be removed.
    static func removingLocation(fromFileAt url: URL) async -> URL? {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true {
            return removingLocation(fromImageAt: url)
        }
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
            return await removingLocation(fromVideoAt: url)
        }
        return url
    }

    /// Image bytes without a location; the same bytes when there was none.
    static func removingLocation(fromImageData data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return data  // not an image ImageIO can read, so nothing it can carry
        }
        guard imageHasLocation(source) else { return data }
        guard let type = CGImageSourceGetType(source) else { return nil }
        var out = NSMutableData()
        let written = writeWithoutLocation(source, makeDestination: {
            out = NSMutableData()
            return CGImageDestinationCreateWithData(out, type, CGImageSourceGetCount(source), nil)
        }, isClean: {
            CGImageSourceCreateWithData(out, nil).map { !imageHasLocation($0) } ?? false
        })
        return written ? out as Data : nil
    }

    // MARK: Images

    private static func removingLocation(fromImageAt url: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return url }
        guard imageHasLocation(source) else { return url }
        let outURL = temporaryURL(extension: url.pathExtension)
        guard let type = CGImageSourceGetType(source),
              writeWithoutLocation(source, makeDestination: {
                  try? FileManager.default.removeItem(at: outURL)
                  return CGImageDestinationCreateWithURL(outURL as CFURL, type, CGImageSourceGetCount(source), nil)
              }, isClean: {
                  CGImageSourceCreateWithURL(outURL as CFURL, nil).map { !imageHasLocation($0) } ?? false
              }) else {
            try? FileManager.default.removeItem(at: outURL)
            return nil
        }
        return outURL
    }

    /// GPS in the EXIF dictionary or in XMP, on any frame.
    static func imageHasLocation(_ source: CGImageSource) -> Bool {
        for index in 0..<max(CGImageSourceGetCount(source), 1) {
            if let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
               props[kCGImagePropertyGPSDictionary] != nil {
                return true
            }
            if let xmp = CGImageSourceCopyMetadataAtIndex(source, index, nil),
               CGImageMetadataCopyTagWithPath(xmp, nil, "exif:GPSLatitude" as CFString) != nil
                || CGImageMetadataCopyTagWithPath(xmp, nil, "exif:GPSLongitude" as CFString) != nil {
                return true
            }
        }
        return false
    }

    /// First a lossless copy asking ImageIO to exclude GPS. ImageIO honours
    /// that for JPEG but reports success for HEIC and PNG while keeping the
    /// GPS (measured), so the result is checked, and on a miss every frame is
    /// re-encoded with the GPS dictionary dropped. `isClean` reads back what
    /// was written; nothing is trusted on the encoder's word.
    private static func writeWithoutLocation(
        _ source: CGImageSource,
        makeDestination: () -> CGImageDestination?,
        isClean: () -> Bool
    ) -> Bool {
        if let dest = makeDestination(),
           CGImageDestinationCopyImageSource(dest, source, [kCGImageMetadataShouldExcludeGPS: true] as CFDictionary, nil),
           isClean() {
            return true  // CopyImageSource finalizes the destination itself
        }
        guard let dest = makeDestination() else { return false }
        let drop = [kCGImagePropertyGPSDictionary: kCFNull as Any,
                    kCGImageMetadataShouldExcludeGPS: true,
                    kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        for index in 0..<CGImageSourceGetCount(source) {
            CGImageDestinationAddImageFromSource(dest, source, index, drop)
        }
        return CGImageDestinationFinalize(dest) && isClean()
    }

    // MARK: Videos

    private static func removingLocation(fromVideoAt url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let hasLocation = await videoHasLocation(asset) else {
            // AVFoundation cannot open this container (WebM, MKV…), so it can
            // be neither checked nor rewritten here. Upload as before.
            return url
        }
        guard hasLocation else { return url }

        let fileType: AVFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let outURL = temporaryURL(extension: fileType == .mov ? "mov" : "mp4")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return nil
        }
        // Passthrough: the streams are copied, not re-encoded, so quality and
        // size stay the same. The sharing filter drops location metadata.
        session.outputURL = outURL
        session.outputFileType = session.supportedFileTypes.contains(fileType) ? fileType : session.supportedFileTypes.first
        session.metadataItemFilter = .forSharing()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed,
              await videoHasLocation(AVURLAsset(url: outURL)) == false else {
            try? FileManager.default.removeItem(at: outURL)
            return nil
        }
        return outURL
    }

    /// Nil when the file cannot be read as a movie at all.
    static func videoHasLocation(_ asset: AVAsset) async -> Bool? {
        guard let items = try? await asset.load(.metadata) else { return nil }
        var all = items
        if let tracks = try? await asset.load(.tracks) {
            for track in tracks {
                all += (try? await track.load(.metadata)) ?? []
            }
        }
        return all.contains(where: isLocation)
    }

    private static func isLocation(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyLocation { return true }
        let id = (item.identifier?.rawValue ?? "").lowercased()
        // mdta/com.apple.quicktime.location.ISO6709, udta/%A9xyz, …
        return id.contains("location") || id.contains("6709") || id.contains("%a9xyz")
    }

    private static func temporaryURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("haven-noloc-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }
}
