import CoreGraphics

/// How a video tile draws its frame (`VideoThumbnailView`): whole and centred
/// on a dark tile, never cropped. A phone's portrait video cropped to fill a
/// square showed only its middle and looked zoomed in (Logen 11-11). Photos
/// still fill their tiles. Android: `mediaTileContentScale`.
enum VideoTileFit {
    /// The size [image] is drawn at inside [tile]: as large as fits, shape kept.
    static func drawnSize(image: CGSize, in tile: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, tile.width > 0, tile.height > 0 else { return tile }
        let scale = min(tile.width / image.width, tile.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}
