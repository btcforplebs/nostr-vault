import Foundation

/// Detects media types for URLs, especially those without file extensions (like Blossom hashes)
class MediaTypeDetector {
    static let shared = MediaTypeDetector()
    
    // Cache content types to avoid repeated network requests
    private var contentTypeCache: [URL: String] = [:]
    private let cacheLock = NSLock()
    private let detectionQueue = DispatchQueue(label: "com.haven.media-type-detection", qos: .utility)
    
    private init() {}
    
    /// Synchronously get cached content type, or nil if not cached
    func getCachedContentType(for url: URL) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return contentTypeCache[url]
    }
    
    /// Asynchronously detect content type via HTTP HEAD request and cache the result
    func detectContentType(for url: URL, completion: @escaping (String?) -> Void) {
        // Check cache first
        if let cached = getCachedContentType(for: url) {
            completion(cached)
            return
        }
        
        detectionQueue.async { [weak self] in
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5.0
            
            let semaphore = DispatchSemaphore(value: 0)
            var detectedType: String?
            
            let task = URLSession.shared.dataTask(with: request) { _, response, error in
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200,
                   let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                    detectedType = contentType
                }
                semaphore.signal()
            }
            task.resume()
            
            // Wait for response with timeout
            _ = semaphore.wait(timeout: .now() + 6.0)
            
            // Cache the result
            if let type = detectedType {
                self?.cacheLock.lock()
                self?.contentTypeCache[url] = type
                self?.cacheLock.unlock()
            }
            
            DispatchQueue.main.async {
                completion(detectedType)
            }
        }
    }
    
    /// Check if a content type indicates an image
    func isImageContentType(_ contentType: String) -> Bool {
        let lowercased = contentType.lowercased()
        return lowercased.hasPrefix("image/")
    }
    
    /// Check if a content type indicates a video
    func isVideoContentType(_ contentType: String) -> Bool {
        let lowercased = contentType.lowercased()
        return lowercased.hasPrefix("video/")
    }
    
    /// Check if a content type indicates a GIF
    func isGIFContentType(_ contentType: String) -> Bool {
        let lowercased = contentType.lowercased()
        return lowercased.contains("image/gif")
    }
    
    /// Determine if URL is likely a Blossom hash (64 hex chars, possibly with extension)
    func isBlossom(url: URL) -> Bool {
        let last = url.lastPathComponent
        let pattern = #"^[a-f0-9]{64}(\.[a-z0-9]+)?$"#
        return last.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    
    /// Pre-fetch content types for an array of URLs in the background
    func prefetchContentTypes(for urls: [URL]) {
        for url in urls {
            // Only prefetch for extensionless or Blossom URLs
            if url.pathExtension.isEmpty || isBlossom(url: url) {
                detectContentType(for: url) { _ in
                    // Result is cached, no action needed
                }
            }
        }
    }
}
