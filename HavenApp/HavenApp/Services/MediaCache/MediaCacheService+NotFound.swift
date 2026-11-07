import Foundation
import SwiftUI
import CryptoKit
import AVFoundation
import CoreMedia
import Combine

extension MediaCacheService {
    // MARK: - 404 Tracking

    func isKnown404(url: URL) -> Bool {
        notFoundLock.lock()
        defer { notFoundLock.unlock() }
        return notFoundURLs[url.absoluteString] != nil
    }

    func known404Set() -> Set<String> {
        notFoundLock.lock()
        defer { notFoundLock.unlock() }
        return Set(notFoundURLs.keys)
    }

    /// `announce: false` records the link without posting
    /// `.mediaNotFoundChanged`, for links no media screen shows (avatars).
    func markNotFound(url: URL, announce: Bool = true) {
        notFoundLock.lock()
        let inserted = notFoundURLs.updateValue(Date(), forKey: url.absoluteString) == nil
        if notFoundURLs.count > notFoundMaxCount {
            // Drop the oldest entries to stay within the cap
            let sorted = notFoundURLs.sorted { $0.value < $1.value }
            for (key, _) in sorted.prefix(notFoundURLs.count - notFoundMaxCount) {
                notFoundURLs.removeValue(forKey: key)
            }
        }
        let snapshot = notFoundURLs
        notFoundLock.unlock()
        guard inserted else { return }
        UserDefaults.standard.set(snapshot, forKey: notFoundDefaultsKey)
        if announce {
            NotificationCenter.default.post(name: .mediaNotFoundChanged, object: url)
        }
    }

    func unmarkNotFound(url: URL) {
        notFoundLock.lock()
        let removed = notFoundURLs.removeValue(forKey: url.absoluteString) != nil
        let snapshot = notFoundURLs
        notFoundLock.unlock()
        guard removed else { return }
        UserDefaults.standard.set(snapshot, forKey: notFoundDefaultsKey)
        NotificationCenter.default.post(name: .mediaNotFoundChanged, object: url)
    }
}
