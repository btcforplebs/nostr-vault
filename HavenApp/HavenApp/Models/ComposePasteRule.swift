import Foundation
import UniformTypeIdentifiers

/// Whether ⌘V in the note editor attaches the clipboard's photo or video
/// instead of pasting text. The same rule as iPad's PastesClipboardImage:
/// only an image or a video with no text or link beside it, so pasting words
/// (or a copied file's name) is never taken away. On the Mac ⌘V used to paste
/// nothing for a copied image: the editor is plain text.
///
/// Pure Foundation so MediaLogicTests can test it.
enum ComposePasteRule {
    /// `types`: the pasteboard's type identifiers.
    static func pastesMedia(types: [String]) -> Bool {
        let uts = types.compactMap { UTType($0) }
        let media = uts.contains { $0.conforms(to: .image) || $0.conforms(to: .movie) }
        let words = uts.contains { $0.conforms(to: .text) || $0.conforms(to: .url) }
            || types.contains("NSStringPboardType") || types.contains("NSFilenamesPboardType")
        return media && !words
    }
}
