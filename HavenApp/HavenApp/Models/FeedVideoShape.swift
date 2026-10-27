import CoreGraphics

/// The box a feed video plays in: the video's own shape, never taller than a
/// cap. A portrait video that would pass the cap gets narrower instead of being
/// cut, so nothing is cropped off its sides or ends.
enum FeedVideoShape {
    /// Portraits never take more than this much height, so one video does not
    /// fill the whole screen.
    static let portraitCeiling: CGFloat = 520

    /// Width / height of a picture `size`, or nil until it has both sides.
    static func ratio(of size: CGSize) -> CGFloat? {
        guard size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }

    /// Tallest the box may be: `landscapeCap` until the shape is known and for
    /// landscape or square video; `portraitCap` (at most `portraitCeiling`)
    /// for portrait.
    static func heightCap(ratio: CGFloat?, landscapeCap: CGFloat, portraitCap: CGFloat) -> CGFloat {
        guard let ratio, ratio > 0, ratio < 1 else { return landscapeCap }
        return min(portraitCap, portraitCeiling)
    }

    /// Widest the box may be so a video of `ratio` fits under `heightCap`
    /// whole. Unlimited while the shape is unknown.
    static func maxWidth(ratio: CGFloat?, heightCap: CGFloat) -> CGFloat {
        guard let ratio, ratio > 0 else { return .infinity }
        return heightCap * ratio
    }
}
