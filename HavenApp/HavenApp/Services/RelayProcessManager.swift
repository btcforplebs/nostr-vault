import Foundation
@preconcurrency import Dispatch
import Combine
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

@MainActor
class RelayProcessManager: ObservableObject {
    static let shared = RelayProcessManager()
    enum RelayState {
        case idle
        case booting
        case running
        case stopping
        case importing
    }
    
    @Published var state: RelayState = .idle
    @Published var isRunning = false
    @Published var isBooting = false
    @Published var isWotSyncing = false
    /// The relay has logged "subscribing to inbox" this run. With a warm WoT
    /// cache that line comes BEFORE "listening at" (boot done), so boot-done
    /// must not turn Syncing on after it: nothing would ever turn it off, and
    /// an always-on Mac sat on "Syncing" for good (2026-10-03).
    var inboxSubscribed = false
    @Published var isImporting = false
    @Published var importCompleted = false {
        didSet { if importCompleted && !oldValue { VaultHistory.lastNotesImport = Date() } }
    }
    @Published var isLocked = false
    @Published var isPortConflict = false
    @Published var bootStatusMessage: String = ""
    @Published var importStatusMessage: String = ""
    @Published var importProgress: Double = 0.0
    
    /// Feed connections should wait until relay is fully ready.
    /// Set `true` 3 seconds after relay reaches `.running` state.
    @Published var isReadyForConnections = false
    var readyForConnectionsTask: Task<Void, Never>?

    // Critical recovery alert
    @Published var showProcessKillAlert = false
    
    /// Logs are in a separate observable so only LogsView redraws on log changes.
    let logStore = LogStore()

    // Metrics
    @Published var memoryUsage: Double = 0
    @Published var cpuUsage: Double = 0
    @Published var activeConnections: Int = 0
    @Published var eventsStored: Int = 0
    /// The Vault lists that events from OTHERS landed in, via your inbox/chat
    /// relay, since you last looked at each. The Vault tab's red dot shows
    /// while any remain; the mode pill marks which.
    @Published var newActivityModes: Set<VaultMode> = []
    var hasNewRelayActivity: Bool { !newActivityModes.isEmpty }

    var outputPipe: Pipe?
    var stderrPipe: Pipe?
    var savedStdout: Int32 = -1
    var savedStderr: Int32 = -1
    private var logBuffer = Data() // Buffer for incomplete log lines
    
    // Track if we are in the middle of a shutdown to prevent recursive restarts
    var isShuttingDown: Bool = false
    
    // Background log processing
    let logProcessingQueue = DispatchQueue(label: "com.haven.relay.logs", qos: .utility)
    
    var pendingImportConfig: HavenConfig?
    /// Import-only extra relays waiting on a stop (see `importNotes`).
    var pendingImportAlsoFrom: [String] = []
    @Published var startDate: Date?
    
    // Auto-fix locks
    @Published var lastConfig: HavenConfig?
    var retryAttempted = false
    var needsLockFix = false

    // Boot watchdog: triggers force restart offer if boot takes too long
    var bootWatchdogTimer: DispatchSourceTimer?
    static let bootWatchdogTimeout: TimeInterval = 90

    // MARK: - Lifecycle serialization

    /// All start/stop/restart/backup operations run strictly one-at-a-time,
    /// in enqueue order. Overlapping a start with a still-running stop used
    /// to race the Go side's lifecycle globals and corrupt BadgerDB.
    var lifecycleChain: Task<Void, Never> = Task {}

    /// Coalescing/cooldown for automatic recovery restarts (Blossom upload
    /// failures). Each restart cycles the embedded Go relay and BadgerDB;
    /// concurrent or rapid-fire restarts are what used to crash the app.
    var inFlightRestart: Task<Bool, Never>?
    var lastRestartFinished: Date?
    static let restartCooldown: TimeInterval = 60

    /// BadgerDB LOCK files are only known-stale on the first start after
    /// process launch. Later in the app's lifetime a LOCK file can belong
    /// to a live in-process Badger instance; deleting it would let two
    /// instances open the same directory and silently corrupt it.
    var hasClearedLocksThisLaunch = false

    /// App Nap suppression token, held while the relay is running so macOS
    /// doesn't throttle the embedded Go runtime's timers and sockets.
    private var relayActivityToken: NSObjectProtocol?

    func beginRelayActivity() {
        guard relayActivityToken == nil else { return }
        relayActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.background, .suddenTerminationDisabled],
            reason: "Haven relay serving connections")
    }

    func endRelayActivity() {
        if let token = relayActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            relayActivityToken = nil
        }
    }

    // (Log throttling moved to LogStore)

    /// Whether the UI is actively visible (popover open / window focused).
    /// When false, background log processing skips LogEntry creation and
    /// non-critical @Published updates to reduce CPU and SwiftUI churn.
    nonisolated(unsafe) private(set) var isUIActive = true

    /// Call when the menu-bar popover closes or app resigns active.
    func enterBackground() {
        guard isUIActive else { return }
        isUIActive = false
        logStore.stopThrottler()
        logStore.isUIActive = false
        // Hand back whatever the last sync/import round left on the Go heap.
        // Off the main thread on purpose: FreeOSMemory runs a full GC (tens to
        // hundreds of ms), and blocking cgo calls on the main thread are what
        // the 0x8BADF00D watchdog kills look like.
        DispatchQueue.global(qos: .utility).async {
            TrimMemoryC()
        }
        #if DEBUG
        print("RelayProcessManager: entering background mode")
        #endif
    }

    /// Call when the menu-bar popover opens or app becomes active.
    func enterForeground() {
        guard !isUIActive else { return }
        isUIActive = true
        logStore.isUIActive = true
        logStore.startThrottler()
        #if DEBUG
        print("RelayProcessManager: entering foreground mode")
        #endif
    }
    
    typealias LogEntry = RelayLogParser.LogEntry
    
    /// `mode` is on screen, so what came into it has been seen.
    func markRelayViewed(_ mode: VaultMode) {
        // The Vault list shows everything, so seeing it sees every list.
        if mode == .activity {
            if !newActivityModes.isEmpty { newActivityModes = [] }
            return
        }
        if newActivityModes.contains(mode) { newActivityModes.remove(mode) }
    }

    /// How long the HTTP check keeps trying once the flags say running.
    static let httpReadyTimeout: TimeInterval = 10

    /// HEAD /upload until the relay answers, backing off 0.25s → 2s.
    func waitForHTTP(timeout: TimeInterval = httpReadyTimeout) async -> Bool {
        let port = lastConfig?.relayPort ?? ConfigService.shared.config.relayPort
        let deadline = Date().addingTimeInterval(timeout)
        var delay: TimeInterval = 0.25
        while true {
            if await Self.relayAnswersHTTP(port: port) { return true }
            if Date().addingTimeInterval(delay) >= deadline { return false }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delay = min(delay * 2, 2)
        }
    }

    static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
    }()

    #if os(iOS)
    private var foregroundObserver: NSObjectProtocol?

    /// On iOS the app restarts the relay on foreground only when it is idle.
    /// A relay whose socket died during suspension still reads as running, so
    /// check that it answers; if not, reopen its port, and restart it only
    /// if that does not bring it back.
    func observeForegroundOnce() {
        guard foregroundObserver == nil else { return }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await RelayProcessManager.shared.recheckAfterForeground() }
        }
    }

    func recheckAfterForeground() async {
        guard state == .running, isRunning, !isBooting, inFlightRestart == nil, !isApplyingConfig else { return }
        // A few tries: right after resume the process is still thawing.
        if await waitForHTTP(timeout: 4) { return }
        guard state == .running else { return }  // stopped or restarting meanwhile
        // Suspension took the listening socket; the rest of the relay is
        // fine. Reopen just the port and keep databases and sync running.
        logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Relay is not answering after the app came back; reopening its port"))
        let reopened = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { continuation.resume(returning: RelistenRelayC() == 0) }
        }
        if reopened, await waitForHTTP(timeout: 2) { return }
        guard state == .running, inFlightRestart == nil else { return }
        logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Relay still not answering after reopening its port; restarting it"))
        _ = await gracefulRestart()
    }
    #endif

    /// True while a settings save is restarting the relay onto a new config.
    @Published var isApplyingConfig = false
    var pendingAppliedConfig: HavenConfig?
    var applyConfigTask: Task<Void, Never>?

    /// How long saves must stop arriving before a restart, so a value typed
    /// with pauses (a port, a domain) restarts the relay once, not per pause.
    static let applyQuietPeriod: TimeInterval = 3
    /// Minimum time between the end of one settings restart and the start of
    /// the next. Rapid stop/start cycling is what used to corrupt BadgerDB.
    static let applyMinimumGap: TimeInterval = 10
    var lastApplyRequest = Date.distantPast
    
    /// Persistent file handle for relay.log — opened once, reused for the
    /// lifetime of the pipe to avoid file-descriptor churn.
    var logFileHandle: FileHandle?

    // Fallback map for MIME types that UTType may not know on all macOS versions
    nonisolated static let extensionFallbacks: [String: String] = [
        "application/vnd.android.package-archive": "apk",
        "application/java-archive": "jar",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "audio/x-m4a": "m4a",
        "audio/mp4": "m4a",
        "audio/aac": "aac",
        "audio/opus": "opus",
        "video/x-matroska": "mkv",
        "image/svg+xml": "svg",
        "application/x-tar": "tar",
        "application/gzip": "gz",
    ]
}
