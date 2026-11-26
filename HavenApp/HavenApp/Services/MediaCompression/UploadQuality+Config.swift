import Foundation

extension UploadQuality {
    /// The quality the user picked in Settings. Read it on the main actor
    /// before starting work off it, then pass the value along.
    @MainActor static var current: ImageCompressor.Quality {
        from(ConfigService.shared.config.uploadQuality)
    }
}
