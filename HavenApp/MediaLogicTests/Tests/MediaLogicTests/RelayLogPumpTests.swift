import XCTest
import Darwin
@testable import MediaLogic

/// The relay log reader on .99 (2026-11-11): one queued block per pipe read,
/// held until a slow parser got to it, grew to 12 GB. The pump must keep
/// what waits for the parser capped however fast the relay writes.
final class RelayLogPumpTests: XCTestCase {

    // MARK: - Memory stays capped

    /// Flood the pump while its queue cannot drain at all (the parser
    /// "infinitely slow"), then measure the process's real memory.
    func testFloodFasterThanTheDrainKeepsMemoryCapped() {
        let queue = DispatchQueue(label: "test.relay.logs.flood")
        queue.suspend()
        let received = LockedLines()
        let pump = RelayLogPump(fileHandle: nil, queue: queue, cap: 1024 * 1024) { received.add($0) }

        // 64 KB chunks of whole log lines, like a pipe read.
        let line = String(repeating: "x", count: 99) + "\n"
        let chunk = Data(String(repeating: line, count: 655).utf8)
        let floodBytes = 256 * 1024 * 1024

        let before = Self.physFootprint()
        var sent = 0
        var n = 0
        while sent < floodBytes {
            // A fresh Data per read, as availableData gives.
            var piece = chunk
            piece.append(Data("n\(n)\n".utf8))
            pump.ingest(piece, from: n % 7 == 0 ? .stderr : .stdout)
            sent += piece.count
            n += 1
        }
        let grown = Self.physFootprint() - before

        XCTAssertLessThanOrEqual(pump.bufferedBytes, 1024 * 1024 + chunk.count,
                                 "bytes waiting for the parser must stay at the cap")
        XCTAssertLessThan(grown, 32 * 1024 * 1024,
                          "flooded \(floodBytes >> 20) MB, memory grew \(grown >> 20) MB")
        XCTAssertLessThanOrEqual(pump.scheduledDrains, 1, "one drain at a time, not one block per read")

        queue.resume()
        queue.sync {}
        let text = received.all.joined()
        XCTAssertTrue(text.contains("KB of relay log dropped"), "the parser is told what was dropped")
        XCTAssertTrue(text.contains("n\(n - 1)\n"), "the newest lines survive")
        XCTAssertFalse(text.contains("\nn0\n"), "the oldest lines were the ones dropped")
        XCTAssertEqual(pump.bufferedBytes, 0)
    }

    /// The .99 case: the drain runs, just slower than two streams writing
    /// at once. Waiting bytes never pass the cap and every drain ends.
    func testSlowDrainUnderConcurrentFloodStaysCapped() {
        for round in 0..<20 {
            let queue = DispatchQueue(label: "test.relay.logs.slow.\(round)")
            let received = LockedLines()
            let pump = RelayLogPump(fileHandle: nil, queue: queue, cap: 64 * 1024) { text in
                received.add(text)
                Thread.sleep(forTimeInterval: 0.0005)
            }
            let chunk = Data(String(repeating: String(repeating: "y", count: 63) + "\n", count: 64).utf8)
            let maxSeen = LockedMax()
            DispatchQueue.concurrentPerform(iterations: 2) { worker in
                for i in 0..<400 {
                    var piece = chunk
                    piece.append(Data("w\(worker)-\(i)\n".utf8))
                    pump.ingest(piece, from: worker == 0 ? .stdout : .stderr)
                    maxSeen.see(pump.bufferedBytes)
                }
            }
            queue.sync {}
            XCTAssertLessThanOrEqual(maxSeen.value, 64 * 1024 + 2 * chunk.count, "round \(round)")
            XCTAssertEqual(pump.bufferedBytes, 0, "round \(round): a drain stopped with lines left")
            let text = received.all.joined()
            XCTAssertTrue(text.contains("w0-399\n") && text.contains("w1-399\n"), "round \(round): last lines lost")
            // After the drain ended, a new read must schedule a new drain.
            pump.ingest(Data("after\n".utf8), from: .stdout)
            queue.sync {}
            XCTAssertTrue(received.all.joined().hasSuffix("after\n"), "round \(round)")
        }
    }

    // MARK: - Lines

    func testLinesSplitAcrossReadsArriveWhole() {
        let queue = DispatchQueue(label: "test.relay.logs.split")
        let received = LockedLines()
        let pump = RelayLogPump(fileHandle: nil, queue: queue) { received.add($0) }
        pump.ingest(Data("first li".utf8), from: .stdout)
        pump.ingest(Data("ne\nsecond".utf8), from: .stdout)
        queue.sync {}
        XCTAssertEqual(received.all.joined(), "first line\n")
        pump.ingest(Data(" line\n".utf8), from: .stdout)
        queue.sync {}
        XCTAssertEqual(received.all.joined(), "first line\nsecond line\n")
    }

    /// stdout and stderr keep separate partial lines, so a half line on
    /// one is never glued to a line from the other.
    func testStreamsDoNotGlueHalfLines() {
        let queue = DispatchQueue(label: "test.relay.logs.glue")
        let received = LockedLines()
        let pump = RelayLogPump(fileHandle: nil, queue: queue) { received.add($0) }
        pump.ingest(Data("out half".utf8), from: .stdout)
        pump.ingest(Data("err line\n".utf8), from: .stderr)
        pump.ingest(Data(" done\n".utf8), from: .stdout)
        queue.sync {}
        let lines = received.all.joined().split(separator: "\n").map(String.init).sorted()
        XCTAssertEqual(lines, ["err line", "out half done"])
    }

    /// A drop that cuts into the middle of a line drops the rest of that
    /// line too, so the parser never sees a fragment.
    func testDropsWholeLinesOnly() {
        let queue = DispatchQueue(label: "test.relay.logs.whole")
        queue.suspend()
        let received = LockedLines()
        let pump = RelayLogPump(fileHandle: nil, queue: queue, cap: 64) { received.add($0) }
        for i in 0..<40 { pump.ingest(Data("line-\(i)-abcdef\n".utf8), from: .stdout) }
        queue.resume()
        queue.sync {}
        for raw in received.all.joined().split(separator: "\n") {
            let s = String(raw)
            XCTAssertTrue(s.hasPrefix("line-") && s.hasSuffix("-abcdef") || s.contains("dropped"), "fragment: \(s)")
        }
        XCTAssertTrue(received.all.joined().contains("line-39-abcdef"))
    }

    // MARK: - relay.log

    /// stderr goes to relay.log directly and still reaches the parser,
    /// through real pipes as captureOutput wires them.
    func testStderrAndStdoutLinesReachRelayLogAndParser() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relaylogpump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("relay.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }

        let queue = DispatchQueue(label: "test.relay.logs.file")
        let received = LockedLines()
        let pump = RelayLogPump(fileHandle: handle, queue: queue) { received.add($0) }
        let out = Pipe(), err = Pipe()
        pump.attach(out, as: .stdout)
        pump.attach(err, as: .stderr)
        defer {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }

        err.fileHandleForWriting.write(Data("2026/11/11 21:00:00 ERROR from stderr\n".utf8))
        out.fileHandleForWriting.write(Data("2026/11/11 21:00:01 INFO from stdout\n".utf8))

        let deadline = Date().addingTimeInterval(5)
        var file = ""
        while Date() < deadline {
            queue.sync {}
            file = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if file.contains("from stderr"), file.contains("from stdout"),
               received.all.joined().contains("from stderr"), received.all.joined().contains("from stdout") { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(file.contains("ERROR from stderr\n"), "relay.log: \(file)")
        XCTAssertTrue(file.contains("INFO from stdout\n"), "relay.log: \(file)")
        XCTAssertEqual(file.components(separatedBy: "from stderr").count - 1, 1, "stderr written once, not echoed twice")
        XCTAssertTrue(received.all.joined().contains("ERROR from stderr\n"))
        XCTAssertTrue(received.all.joined().contains("INFO from stdout\n"))
    }

    /// relay.log keeps every byte even while the parser side drops.
    func testRelayLogKeepsEverythingWhileTheParserDrops() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relaylogpump-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        let queue = DispatchQueue(label: "test.relay.logs.keep")
        queue.suspend()
        let pump = RelayLogPump(fileHandle: handle, queue: queue, cap: 1024) { _ in }
        var total = 0
        for i in 0..<500 {
            let d = Data("keep line \(i)\n".utf8)
            pump.ingest(d, from: i % 2 == 0 ? .stdout : .stderr)
            total += d.count
        }
        queue.resume()
        queue.sync {}
        try handle.close()
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written.count, total)
        XCTAssertLessThanOrEqual(pump.bufferedBytes, 1024)
    }

    // MARK: - Helpers

    static func physFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}

private final class LockedMax: @unchecked Sendable {
    private let lock = NSLock()
    private var top = 0
    func see(_ v: Int) { lock.lock(); top = max(top, v); lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return top }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
