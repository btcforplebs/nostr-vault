import Foundation

struct MediaItem: Identifiable, Codable {
    let id: UUID
    let url: URL
    let type: MediaType
    let dateAdded: Date
    let pubkey: String? // Author of the event containing this media
    let tags: [[String]]? // Tags of the event containing this media
    let mimeType: String?

    enum MediaType: String, Codable {
        case image
        case video
        case audio
        case unknown
    }
}
