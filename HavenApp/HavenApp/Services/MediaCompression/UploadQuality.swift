import Foundation

/// Settings › Media Servers › Upload Quality (Logen 2026-11-26, RESEARCH
/// NV_UPLOAD_COMPRESSION §6, plan A4). One setting, no switch on each
/// attachment:
/// - "standard" (the default): photos you post, share, send in live chat or
///   in a DM are shrunk (`ImageCompressor`), and videos too (`VideoCompressor`).
/// - "original": they go up as they are.
///
/// Location is removed either way (`MediaPrivacy` runs after). The Media tab
/// always uploads originals and doesn't read this. The saved value is
/// `HavenConfig.uploadQuality`; read it through `UploadQuality.current`.
/// Android twin: `service/media/UploadQuality.kt` (#2561).
enum UploadQuality {
    static let standard = "standard"
    static let original = "original"

    /// The saved setting as a quality; anything unknown is Standard.
    static func from(_ setting: String) -> ImageCompressor.Quality {
        setting == original ? .original : .standard
    }

    /// The setting as one of `standard` / `original`.
    static func normalized(_ setting: String) -> String {
        setting == original ? original : standard
    }

    /// The words beside the row in Settings.
    static func label(_ setting: String) -> String {
        from(setting) == .original ? "Original" : "Standard"
    }
}
