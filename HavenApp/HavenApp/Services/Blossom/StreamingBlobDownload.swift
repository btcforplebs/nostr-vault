import Foundation
import CryptoKit

/// Whether a file of `declared` bytes may be brought into the vault with
/// `free` bytes left on this device. The download lands in a temp file and the
/// vault then stores its own copy, so a file needs about twice its size, plus
/// a margin so the phone is never filled to the last byte. Before the size is
/// known (no Content-Length) only the margin is asked for; the full rule runs
/// again once the file is down.
enum BlobImportRoom: Equatable {
    case fits
    case noRoom(need: Int64, free: Int64)

    /// Kept free on top of the copies.
    static let margin: Int64 = 256 << 20

    static func decide(declared: Int64?, free: Int64) -> BlobImportRoom {
        let size = max(declared ?? 0, 0)
        let need = size.multipliedReportingOverflow(by: 2).overflow ? Int64.max : size * 2 + margin
        return free >= need ? .fits : .noRoom(need: need, free: free)
    }

    /// After the download: the temp file already sits on the disk, so only
    /// the vault's copy (and the margin) still has to fit.
    static func decideAfterDownload(size: Int64, free: Int64) -> BlobImportRoom {
        let need = max(size, 0) + margin
        return free >= need ? .fits : .noRoom(need: need, free: free)
    }

    /// One plain sentence for the log and the person.
    var reason: String? {
        guard case .noRoom(let need, let free) = self else { return nil }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "Needs \(f.string(fromByteCount: need)) free, this device has \(f.string(fromByteCount: free))"
    }

    /// Free bytes on the volume holding `url` (the app's own container), or
    /// nil when the system won't say.
    static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}

/// Downloads one file straight to a temp file, hashing it as it arrives, so a
/// big video never sits in memory whole: each chunk is hashed, written and
/// dropped. The room check runs as soon as the headers say how big the file
/// is, before the body is read. On any failure the temp file is gone.
final class StreamingBlobDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Challenge = @Sendable (URLAuthenticationChallenge, @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void

    struct File: Equatable {
        let url: URL
        let sha256: String
        let size: Int64
        let contentType: String
    }

    enum Failure: Error, Equatable {
        case status(Int)
        case noRoom(BlobImportRoom)
        case hashMismatch(expected: String, got: String)
        case disk(String)
        case network(String)
        case cancelled

        var reason: String {
            switch self {
            case .status(let code): return "the server answered \(code)"
            case .noRoom(let room): return room.reason ?? "no room"
            case .hashMismatch(let expected, let got): return "file is not \(expected.prefix(8)) (got \(got.prefix(8)))"
            case .disk(let why): return "could not write the file: \(why)"
            case .network(let why): return why
            case .cancelled: return "cancelled"
            }
        }
    }

    /// Fetches `request` into a new file in `directory`. `expectedSHA256`
    /// (lower-case hex) is checked when given. `freeBytes` is asked twice:
    /// at the headers and once the file is down.
    static func fetch(_ request: URLRequest,
                      configuration: URLSessionConfiguration,
                      directory: URL = FileManager.default.temporaryDirectory,
                      expectedSHA256: String? = nil,
                      freeBytes: @escaping @Sendable () -> Int64? = { BlobImportRoom.freeBytes(at: FileManager.default.temporaryDirectory) },
                      challenge: Challenge? = nil,
                      observe: ((StreamingBlobDownload) -> Void)? = nil) async -> Result<File, Failure> {
        let target = directory.appendingPathComponent("import-\(UUID().uuidString).part")
        let download = StreamingBlobDownload(target: target, expected: expectedSHA256?.lowercased(),
                                             freeBytes: freeBytes, challenge: challenge)
        observe?(download)
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                download.start(task, continuation)
            }
        } onCancel: {
            download.cancel(task)
        }
    }

    private let target: URL
    private let expected: String?
    private let freeBytes: @Sendable () -> Int64?
    private let challenge: Challenge?
    private let lock = NSLock()
    private var handle: FileHandle?
    private var hasher = SHA256()
    private var written: Int64 = 0
    private var failure: Failure?
    private var cancelled = false
    private var contentType = "application/octet-stream"
    private var continuation: CheckedContinuation<Result<File, Failure>, Never>?
    /// The most body bytes this download ever held at once (one chunk), for tests.
    private(set) var peakChunkBytes = 0

    private init(target: URL, expected: String?, freeBytes: @escaping @Sendable () -> Int64?,
                 challenge: Challenge?) {
        self.target = target
        self.expected = expected
        self.freeBytes = freeBytes
        self.challenge = challenge
    }

    private func start(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<Result<File, Failure>, Never>) {
        let alreadyCancelled = lock.withLock { () -> Bool in
            if !cancelled { self.continuation = continuation }
            return cancelled
        }
        if alreadyCancelled { continuation.resume(returning: .failure(.cancelled)) } else { task.resume() }
    }

    private func cancel(_ task: URLSessionDataTask) {
        lock.withLock {
            cancelled = true
            if failure == nil { failure = .cancelled }
        }
        task.cancel()
    }

    /// Records the first failure; the task is cancelled by the caller.
    private func fail(_ why: Failure) {
        lock.withLock { if failure == nil { failure = why } }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let handle = self.challenge {
            handle(challenge, completionHandler)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            fail(.status(status))
            completionHandler(.cancel)
            return
        }
        let declared = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        if let free = freeBytes() {
            let room = BlobImportRoom.decide(declared: declared, free: free)
            if room != .fits {
                fail(.noRoom(room))
                completionHandler(.cancel)
                return
            }
        }
        do {
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let opened = try FileHandle(forWritingTo: target)
            lock.withLock {
                handle = opened
                contentType = response.mimeType ?? "application/octet-stream"
            }
            completionHandler(.allow)
        } catch {
            fail(.disk(error.localizedDescription))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let ok = lock.withLock { () -> Bool in
            guard failure == nil, let handle else { return false }
            peakChunkBytes = max(peakChunkBytes, chunk.count)
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                failure = .disk(error.localizedDescription)
                return false
            }
            hasher.update(data: chunk)
            written += Int64(chunk.count)
            return true
        }
        if !ok { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (result, continuation) = lock.withLock { () -> (Result<File, Failure>, CheckedContinuation<Result<File, Failure>, Never>?) in
            defer { self.continuation = nil }
            try? handle?.close()
            handle = nil
            let outcome = finish(error)
            if case .failure = outcome { try? FileManager.default.removeItem(at: target) }
            return (outcome, self.continuation)
        }
        continuation?.resume(returning: result)
    }

    /// Called under the lock, after the file is closed.
    private func finish(_ error: Error?) -> Result<File, Failure> {
        if let failure { return .failure(failure) }
        if let error { return .failure(.network(error.localizedDescription)) }
        let sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expected, sha != expected { return .failure(.hashMismatch(expected: expected, got: sha)) }
        if let free = freeBytes() {
            let room = BlobImportRoom.decideAfterDownload(size: written, free: free)
            if room != .fits { return .failure(.noRoom(room)) }
        }
        return .success(File(url: target, sha256: sha, size: written, contentType: contentType))
    }
}
