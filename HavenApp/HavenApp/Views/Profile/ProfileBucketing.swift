import Foundation

/// The profile's notes split by tab.
struct ProfileNoteBuckets {
    var top: [FeedNote] = []
    var media: [FeedNote] = []
    var replies: [FeedNote] = []
    var reposts: [FeedNote] = []
    var tagged: [FeedNote] = []
}
