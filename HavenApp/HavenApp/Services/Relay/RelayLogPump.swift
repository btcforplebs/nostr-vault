import Foundation

/// Moves the relay's stdout and stderr into relay.log and on to the line
/// parser, with a hard cap on what waits for the parser.
///
/// Why (Mac 3.2.1 (19) on .99, 2026-11-11): the old handler queued one
/// block per pipe read, each holding its chunk, on a serial queue whose
/// parser could not keep up with ~80 KB/s of log. Nothing bounded that
/// backlog and it reached 12 GB on an 8 GB Mac.
///
/// Now:
/// - Every read is written to relay.log at once, from the reading thread,
///   so the file keeps every byte (stderr goes straight there too, not
///   back through the stdout pipe).
/// - The read is appended to one capped buffer per stream, and a drain is
///   scheduled only if none is pending. Over the cap the oldest whole lines
///   are dropped and the parser gets one "N KB of relay log dropped" line.
/// - Nothing ever waits on the parser, so Go never blocks on a full pipe
///   (that deadlocked goroutines before).
final class RelayLogPump: @unchecked Sendable {
    enum Stream: CaseIterable { case stdout, stderr }

    /// What may wait for the parser, both streams together.
    static let defaultCap = 1024 * 1024

    private let fileHandle: FileHandle?
    private let queue: DispatchQueue
    private let perStreamCap: Int
    private let process: @Sendable (String) -> Void

    private let lock = NSLock()
    private let fileLock = NSLock()
    private var buffers: [Stream: Data] = [.stdout: Data(), .stderr: Data()]
    private var droppedBytes = 0
    private var drainPending = false
    /// Drains put on the queue so far (tests: one at a time, not one per read).
    private(set) var scheduledDrains = 0

    init(fileHandle: FileHandle?, queue: DispatchQueue, cap: Int = RelayLogPump.defaultCap,
         process: @escaping @Sendable (String) -> Void) {
        self.fileHandle = fileHandle
        self.queue = queue
        self.perStreamCap = max(cap / Stream.allCases.count, 1)
        self.process = process
    }

    /// Bytes waiting for the parser now.
    var bufferedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffers.values.reduce(0) { $0 + $1.count }
    }

    /// Reads `pipe` into the pump. The handler keeps the pump alive until
    /// it is cleared (`readabilityHandler = nil`).
    func attach(_ pipe: Pipe, as stream: Stream) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.ingest(data, from: stream)
        }
    }

    /// One pipe read. Cheap and never blocks on the parser.
    func ingest(_ data: Data, from stream: Stream) {
        guard !data.isEmpty else { return }
        if let fileHandle {
            fileLock.lock()
            try? fileHandle.write(contentsOf: data)
            fileLock.unlock()
        }

        lock.lock()
        var buffer = buffers[stream] ?? Data()
        buffers[stream] = nil // keep one reference so append doesn't copy
        buffer.append(data)
        if buffer.count > perStreamCap {
            droppedBytes += Self.dropOldest(&buffer, keep: perStreamCap / 2)
        }
        buffers[stream] = buffer
        let schedule = !drainPending
        if schedule {
            drainPending = true
            scheduledDrains += 1
        }
        lock.unlock()

        if schedule {
            queue.async { self.drain() }
        }
    }

    /// Hands every complete line to the parser until nothing is left.
    private func drain() {
        while let text = takeCompleteLines() {
            process(text)
        }
    }

    /// Complete lines waiting now, or nil (and the drain ends) if none.
    private func takeCompleteLines() -> String? {
        lock.lock()
        defer { lock.unlock() }
        var out = Data()
        if droppedBytes > 0 {
            let kb = max(droppedBytes / 1024, 1)
            out.append(Data("WARN: \(kb) KB of relay log dropped before parsing (reader fell behind; relay.log has it all)\n".utf8))
            droppedBytes = 0
        }
        for stream in Stream.allCases {
            guard var buffer = buffers[stream], let nl = buffer.lastIndex(of: 0x0A) else { continue }
            buffers[stream] = nil
            out.append(buffer[buffer.startIndex...nl])
            buffer = Data(buffer[buffer.index(after: nl)...])
            buffers[stream] = buffer
        }
        guard !out.isEmpty else {
            drainPending = false
            return nil
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Drops the oldest bytes so at most about `keep` remain, cutting only
    /// after a newline so no line arrives as a fragment. Returns bytes dropped.
    private static func dropOldest(_ buffer: inout Data, keep: Int) -> Int {
        let before = buffer.count
        let cut = buffer.index(buffer.startIndex, offsetBy: max(before - keep, 0))
        if let nl = buffer[cut...].firstIndex(of: 0x0A) {
            buffer = Data(buffer[buffer.index(after: nl)...])
        } else {
            buffer = Data()
        }
        return before - buffer.count
    }
}
