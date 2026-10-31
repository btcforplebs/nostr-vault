import Foundation

/// Which pages to load ahead of a swipe: the one after first (the usual
/// direction), then the one before. Never the current page, never out of range.
enum PagerNeighbors {
    static func indices(around index: Int, count: Int) -> [Int] {
        guard count > 1, (0..<count).contains(index) else { return [] }
        return [index + 1, index - 1].filter { (0..<count).contains($0) }
    }

    /// The neighbours of `selected` in `items`, by position. A note that repeats
    /// an image resolves to its first occurrence, which is the page the viewer
    /// opens on for that URL anyway.
    static func neighbors<T: Equatable>(of selected: T, in items: [T]) -> [T] {
        guard let i = items.firstIndex(of: selected) else { return [] }
        return indices(around: i, count: items.count).map { items[$0] }
    }
}
