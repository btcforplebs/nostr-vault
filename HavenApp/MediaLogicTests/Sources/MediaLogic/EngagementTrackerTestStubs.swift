import Foundation

// Stand-in for NoteStats, which lives in FeedServiceTypes.swift alongside
// types that cannot build here. Same fields as the app's.
struct NoteStats: Equatable, Codable {
    var reactions: Int = 0
    var reposts: Int = 0
    var zaps: Int = 0
}
