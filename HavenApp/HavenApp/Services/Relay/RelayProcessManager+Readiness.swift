import Foundation
@preconcurrency import Dispatch
import Combine
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

extension RelayProcessManager {
    /// Waits for the relay to be ready (running, not booting).
    /// Returns true if ready, false on timeout or if relay is idle/stopping.
    func ensureRelayReady(timeout: TimeInterval = 15.0) async -> Bool {
        if isRunning && !isBooting { return true }
        if state == .idle || state == .stopping { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning && !isBooting { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return isRunning && !isBooting
    }

    /// Ready by the flags AND answering HTTP. The flags alone go stale: iOS
    /// can close the listening socket while the app is suspended and nothing
    /// flips `isRunning`, so an upload only found out by failing.
    func ensureRelayServing(timeout: TimeInterval = 15.0) async -> Bool {
        let started = Date()
        guard await ensureRelayReady(timeout: timeout) else { return false }
        let left = timeout - Date().timeIntervalSince(started)
        return await waitForHTTP(timeout: max(left, Self.httpReadyTimeout))
    }

    /// One request to the relay's own Blossom endpoint. Any HTTP status
    /// counts: a 401 or 404 still means the listener is up. Only a connection
    /// failure or a timeout means it is not.
    nonisolated static func relayAnswersHTTP(port: Int) async -> Bool {
        #if os(macOS)
        guard let url = URL(string: "http://127.0.0.1:\(port)/upload") else { return false }
        #else
        guard let url = URL(string: "https://localhost:\(port)/upload") else { return false }
        #endif
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 2
        guard let (_, response) = try? await probeSession.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (100..<600).contains(http.statusCode)
    }
    

    // MARK: - Boot Watchdog

    func startBootWatchdog() {
        cancelBootWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.bootWatchdogTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isBooting else { return }
            self.logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Boot watchdog triggered after \(Int(Self.bootWatchdogTimeout))s — offering force restart"))
            self.showProcessKillAlert = true
        }
        timer.resume()
        bootWatchdogTimer = timer
    }

    func cancelBootWatchdog() {
        bootWatchdogTimer?.cancel()
        bootWatchdogTimer = nil
    }
}
