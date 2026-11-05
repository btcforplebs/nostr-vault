import Foundation

/// When an import request may start, and when setup should say it didn't.
///
/// LogePhone, 2026-11-05: setup's import tour asked for the import while the
/// vault was still booting. `importNotes` only handled idle and running, so
/// it logged a WARN and dropped the request: the tour sat on its first stage
/// for good and the Go side never saw an import. Requests now wait on the
/// relay lifecycle chain and start once the vault has settled; a start the Go
/// side refuses (the last cycle still draining) is retried.
///
/// Pure Foundation so MediaLogicTests can test it; RelayProcessManager maps
/// its own state onto `Vault`.
enum ImportStartGate {
    enum Vault {
        case idle, booting, running, stopping, importing
    }

    enum Action: Equatable {
        /// Idle and down: start the import now.
        case start
        /// The relay is up (or coming up): stop it, then import.
        case stopThenStart
        /// Between states: hold the request and look again shortly.
        case wait
        /// An import is already running; this request joins it.
        case alreadyImporting
    }

    static func action(vault: Vault, isRunning: Bool, isShuttingDown: Bool) -> Action {
        switch vault {
        case .importing:
            return .alreadyImporting
        case .idle where !isRunning && !isShuttingDown:
            return .start
        case .running where isRunning, .booting where isRunning:
            return .stopThenStart
        default:
            // .booting before StartRelayC(0) was called, .stopping, or idle
            // with a shutdown still finishing.
            return .wait
        }
    }

    /// How long a held request waits before looking again.
    static let waitInterval: TimeInterval = 1
    /// Held this many times in a row: give up (the screen offers Try again).
    static let maxWaits = 30

    // MARK: Refused starts

    /// What the Go side said when it did not run an import (cshared.go
    /// runImportCycle). Refused and ignored are worth a retry once the last
    /// cycle has drained; aborted (no seed relay answered) is not.
    enum Refusal: Equatable {
        case retry
        case giveUp
    }

    static func refusal(in line: String) -> Refusal? {
        if line.contains("Import refused") || line.contains("Import ignored") || line.contains("StartRelayC refused") {
            return .retry
        }
        if line.contains("Import aborted") {
            return .giveUp
        }
        return nil
    }

    /// The Go side began the import cycle.
    static func isEngineStart(_ line: String) -> Bool {
        line.contains("is booting up (C-Shared Import Mode)")
    }

    static let maxRefusedRetries = 3
    static let refusedRetryDelay: TimeInterval = 3

    /// `retries`: refused starts already retried for this request.
    static func shouldRetry(_ refusal: Refusal, retries: Int) -> Bool {
        refusal == .retry && retries < maxRefusedRetries
    }

    // MARK: Setup screen

    /// Nothing started this long after the request: say so.
    static let noStartTimeout: TimeInterval = 60
    static let couldNotStart = "Couldn't start, try again"

    static func showsCouldNotStart(requestedAt: Date?, now: Date, engineStarted: Bool, failed: Bool, completed: Bool) -> Bool {
        if completed || engineStarted { return false }
        if failed { return true }
        guard let requestedAt else { return false }
        return now.timeIntervalSince(requestedAt) >= noStartTimeout
    }
}
