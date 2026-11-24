import Foundation
@preconcurrency import Dispatch
import Combine
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

extension RelayProcessManager {
    /// Enqueue a lifecycle operation behind all previously enqueued ones.
    /// Serialization guarantees a start can never overlap an in-flight stop.
    func enqueueLifecycle(_ op: @escaping @MainActor () async -> Void) {
        let prev = lifecycleChain
        lifecyclePending += 1
        lifecycleChain = Task { @MainActor in
            await prev.value
            await op()
            self.lifecyclePending -= 1
        }
    }

    func startRelay(config: HavenConfig, isRetry: Bool = false) {
        enqueueLifecycle { [weak self] in
            await self?.performStart(config: config, isRetry: isRetry)
        }
    }

    /// The launch's start, right inside the launch handler (startup, Logen
    /// 2026-11-14). Queued on the lifecycle chain, the start ran only after
    /// the first frame was drawn: 407 ms on an iPhone 18 Pro, while the
    /// stores open in ~90 ms. Nothing can be on the chain yet at launch and
    /// a fresh process has no drain to wait for, so it runs now, the same
    /// steps as performStart. A slot set to a mesh npub needs a dial first
    /// (seconds), so that start stays queued; other mesh Vaults are dialed
    /// after the start (DesktopVaultsLogic.MeshDial).
    func startRelayAtLaunch(config: HavenConfig) {
        guard LaunchStart.startsNow(chainBusy: lifecyclePending > 0,
                                    draining: RelayDrainingC() == 1,
                                    meshDial: Self.needsMeshDial(config)) else {
            startupMark("engine start queued (chain \(lifecyclePending), draining \(RelayDrainingC()), mesh dial \(Self.needsMeshDial(config)))")
            startRelay(config: config)
            return
        }
        guard claimStart() else { return }
        prepareStart(config: config, isRetry: false)
        #if os(iOS)
        RelayConfiguration.macMeshRelay = nil
        RelayConfiguration.pendingMeshRelay = nil
        #endif
        continueStartRelay(config: config, relayDataDir: ConfigService.shared.relayDataDir)
        #if os(iOS)
        dialMeshVaultsAfterStart(config: config)
        #endif
    }

    private static func needsMeshDial(_ config: HavenConfig) -> Bool {
        meshDial(config) == .beforeStart
    }

    private static func meshDial(_ config: HavenConfig) -> DesktopVaultsLogic.MeshDial {
        #if os(iOS)
        return DesktopVaultsLogic.meshDial(fipsOn: FipsMeshSettings.enabled, slot: config.macRelayURLInEffect,
                                           meshNpubs: config.desktopVaultMeshNpubs)
        #else
        return .none
        #endif
    }

    /// Takes the start: false (and a log line) unless the vault is idle.
    private func claimStart() -> Bool {
        // Strict guard: Must be idle, not running, and not in the middle of a shutdown
        guard state == .idle && !isRunning && !isShuttingDown else {
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Cannot start relay: current state is \(state) (running: \(isRunning), shuttingDown: \(isShuttingDown))"))
            return false
        }
        // Immediately claim the state so no second call can slip through.
        self.state = .booting
        startupMark("engine start asked")
        return true
    }

    /// The actual start sequence. Must only run on the lifecycle chain.
    func performStart(config: HavenConfig, isRetry: Bool) async {
        guard claimStart() else { return }
        // A stop hands its stragglers to a reaper, and Go refuses a start
        // until they finish: a Restart (stop, then start) right away used to
        // be refused and sit on "Booting…". Wait it out here, as backup and
        // restore already do; if it still isn't done, Go's refusal line ends
        // the boot (RelayLogParser.startFailed).
        if RelayDrainingC() == 1 { _ = await waitForRelayDrain() }
        prepareStart(config: config, isRetry: isRetry)

        #if os(iOS)
        await resolveMacMeshRelay(config: config)
        #endif

        continueStartRelay(config: config, relayDataDir: ConfigService.shared.relayDataDir)
        #if os(iOS)
        dialMeshVaultsAfterStart(config: config)
        #endif
    }

    /// The start's own steps before the engine is called: state, locks,
    /// directories, templates.
    private func prepareStart(config: HavenConfig, isRetry: Bool) {
        #if os(iOS)
        observeForegroundOnce()
        #endif
        self.lastConfig = config
        self.isReadyForConnections = false
        self.readyForConnectionsTask?.cancel()

        // Only reset retry flag if this is a fresh start request, not an auto-retry
        if !isRetry {
            self.retryAttempted = false
            self.showProcessKillAlert = false
        }
        self.needsLockFix = false

        // Start log throttler
        startLogThrottler()

        let relayDataDir = ConfigService.shared.relayDataDir

        // 1. Ensure directories exist (I/O)
        RelayConfiguration.ensureDirectories(under: relayDataDir)

        // 2. Clear stale database locks — only on the first start after
        // process launch (see hasClearedLocksThisLaunch). Explicit recovery
        // paths (Fix Locks button, force clean & restart) clear them
        // unconditionally after a confirmed stop.
        if !hasClearedLocksThisLaunch {
            hasClearedLocksThisLaunch = true
            performClearDatabaseLocks(at: relayDataDir)
        }

        // 3. Templates: copied when the app was installed or updated, not
        //    on every launch (startup time).
        copyTemplatesIfChanged(to: relayDataDir)
    }

    #if os(iOS)
    /// Desktop Vaults on the mesh are reached through FIPS, and the first
    /// that answers in Desktop Vaults order becomes MAC_RELAY_URL's local
    /// ws:// address and publish-for-me (Desktop Vaults P3, §2.2 rule 3).
    /// Dialed here, before the start, only when the slot is a mesh npub,
    /// inside one shared budget (Tron M1 on #2506); otherwise this start
    /// takes what the background dial reached, if it asked for this start,
    /// or dials the mesh Vault it already held again on its own (Tron M2 on
    /// #2513, DesktopVaultsLogic.afterStartPick).
    private func resolveMacMeshRelay(config: HavenConfig) async {
        let handedOver = RelayConfiguration.pendingMeshRelay
        RelayConfiguration.pendingMeshRelay = nil
        switch Self.meshDial(config) {
        case .none:
            RelayConfiguration.macMeshRelay = nil
        case .afterStart:
            switch DesktopVaultsLogic.afterStartPick(handedOver: handedOver?.npub, held: RelayConfiguration.macMeshRelay?.npub,
                                                     meshNpubs: config.desktopVaultMeshNpubs) {
            case .take:
                RelayConfiguration.macMeshRelay = handedOver
            case .redial(let npub):
                RelayConfiguration.macMeshRelay = await dialMeshVaults([npub])
            case .none:
                RelayConfiguration.macMeshRelay = nil
            }
        case .beforeStart:
            RelayConfiguration.macMeshRelay = await dialMeshVaults(config.desktopVaultMeshNpubs)
        }
    }

    private func dialMeshVaults(_ npubs: [String]) async -> RelayConfiguration.MacMeshRelay? {
        let found = await DesktopVaultsLogic.firstAnswering(npubs, budget: DesktopVaultsLogic.meshDialBudget) { npub in
            await FipsMeshService.shared.relayWebsocketURL(meshNpub: npub)
        }
        if let found {
            logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Desktop Vault reached over the mesh (\(found.npub.prefix(16))…)"))
            return .init(npub: found.npub, url: found.url)
        }
        logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "No mesh Desktop Vault answered (\(npubs.count) dialed)"))
        return nil
    }

    /// The relay is up over wss; dial the mesh Vaults now and restart once
    /// one answers, so it moves to the mesh (Tron M1 on #2506). One dial at
    /// a time; nothing when the start already holds a mesh Vault.
    private func dialMeshVaultsAfterStart(config: HavenConfig) {
        guard Self.meshDial(config) == .afterStart, RelayConfiguration.macMeshRelay == nil,
              Self.backgroundMeshDial == nil else { return }
        let npubs = config.desktopVaultMeshNpubs
        Self.backgroundMeshDial = Task { @MainActor [weak self] in
            defer { Self.backgroundMeshDial = nil }
            guard let self, let found = await self.dialMeshVaults(npubs) else { return }
            // The relay may have stopped, or the list changed, while dialing.
            guard self.isRunning, RelayConfiguration.macMeshRelay == nil,
                  let current = self.lastConfig, current.desktopVaultMeshNpubs.contains(found.npub) else { return }
            RelayConfiguration.pendingMeshRelay = found
            // This restart skips the 60 s cooldown (Tron F1 on #2506): after
            // a restart (My Devices, the FIPS switch, blossom recovery) the
            // dial answers within seconds and the move to the mesh was lost.
            // It can't loop: it is asked only by a start that holds no mesh
            // Vault, and the start it causes takes `found`.
            self.lastRestartFinished = nil
            _ = await self.gracefulRestart()
            RelayConfiguration.droppingUnusedHandOver(found)
        }
    }

    private static var backgroundMeshDial: Task<Void, Never>?
    #endif

    /// True while stdout goes to relay.log (captureOutput .. restoreOutput).
    nonisolated(unsafe) static var stdoutToRelayLog = false

    /// Public method to add logs from other services
    nonisolated func addLog(_ message: String, level: String = "INFO") {
        // Zap and NWC lines go to relay.log too, so a zap that looked failed can be read back
        // off the device. Written to stdout, they come back into Settings > Logs through the log
        // parser like the relay's own lines, so they are not added here a second time.
        if Self.stdoutToRelayLog, ZapLogLine.isZapLine(message) {
            FileHandle.standardOutput.write(Data(ZapLogLine.line(message, level: level).utf8))
            return
        }
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        Task { @MainActor in
            self.logStore.append(entry)
        }
    }

    private func continueStartRelay(config: HavenConfig, relayDataDir: URL) {
        // Write/Update essential relay files (relays list, blastr relays)
        // We stop writing .env to disk and use environment variables instead
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        // Written from the same inputs applySavedConfig compares, so a setting
        // the relay reads here can never be missed by the auto-restart.
        let inputs = RelayConfiguration.launchInputs(config: config, relayDataDir: relayDataDir)

        // First run: setup also reads their own servers / the other vault.
        RelayConfiguration.writeImportSeedRelays(config: config, under: relayDataDir, alsoFrom: firstRunAlsoFrom ?? [])
        
        let blastrRelaysURL = relayDataDir.appendingPathComponent(config.blastrRelaysFile)
        if let data = try? encoder.encode(inputs.blastrRelays) {
            try? data.write(to: blastrRelaysURL)
        }

        let dmRelaysURL = relayDataDir.appendingPathComponent("relays_dm.json")
        if let data = try? encoder.encode(inputs.dmRelays) {
            try? data.write(to: dmRelaysURL)
        }

        // whitelisted_npubs.json and private_reader_npubs.json
        HavenConfig.writeVaultAccountFiles(whitelist: inputs.whitelistedNpubs, readers: inputs.privateReaderNpubs,
                                           whitelistFile: "whitelisted_npubs.json", under: relayDataDir, encoder: encoder)
        HavenConfig.writeAccountReachFile(inputs.accountReach, under: relayDataDir)
        
        // Write blacklisted_npubs.json
        let blacklistURL = relayDataDir.appendingPathComponent("blacklisted_npubs.json")
        if let data = try? encoder.encode(config.allBlockedNpubsAcrossAccounts) {
            try? data.write(to: blacklistURL)
        }
        
        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Config: \(config.activeImportSeedRelays.count) import relays, \(config.activeBlastrRelays.count) blastr relays, \(config.whitelistedNpubs.count) whitelisted npubs"))

        // Reset conflict state
        self.isPortConflict = false

        let envURL = relayDataDir.appendingPathComponent(".env")
        let envContent = generateMinimalEnv(config: config)
        try? envContent.write(to: envURL, atomically: true, encoding: .utf8)
        
        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Wrote .env to \(envURL.path)"))
        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Working Directory: \(relayDataDir.path)"))
        
        // Prepare environment for C-Shared lib execution
        Self.handToGo(inputs.env)

        // First run keeps the relay to the follows web until the wider web
        // job runs (import_jobs.go effectiveWotDepth), from the very first
        // start before setup is done. Always set: Go keeps these settings
        // between starts.
        let firstRun = ImportJobs.firstRunFlag(settingUp: firstRunAlsoFrom != nil, setupDone: config.hasCompletedSetup)
        Self.handToGo([ImportJobs.firstRunEnv: firstRun])

        // Change working directory so Go creates files in relayDataDir
        FileManager.default.changeCurrentDirectoryPath(relayDataDir.path)

        // Redirect stdout/stderr to capture Go logs
        captureOutput(in: relayDataDir)

        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Captured output natively"))

        self.state = .booting
        isRunning = true
        // The engine's paired set (mesh device keys), before any mesh request.
        Task { @MainActor in MeshDeviceSetSync.push() }
        isBooting = true
        inboxSubscribed = false
        bootStatusMessage = "Starting system..."
        startBootWatchdog()
        beginRelayActivity()

        // Launch the C-Shared relay on a background thread
        startupMark("engine called")
        DispatchQueue.global().async { [weak self] in
            // 0 = false (not in import mode)
            StartRelayC(0)
            
            // StartRelayC returns instantly because http.ListenAndServe runs in a goroutine
            DispatchQueue.main.async {
                self?.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Relay C-Shared process started"))
                // The Vault's rows as soon as the store opens: the read asks
                // again every 20 ms while booting instead of waiting for the
                // "ready" log line (VaultDirectRead.retriesNotReady).
                NostrService.shared.readVaultFromStore()
            }
        }
        
        isLocked = false
        startDate = Date()
        
    }
    
    /// "Clear Locks Only": clear the LOCK files and start, on the lifecycle
    /// chain so it can't race a stop or a start. It used to clear off the
    /// chain and then hit performStart's guard, so the relay stayed down.
    func clearLocksAndStart(config: HavenConfig) {
        let relayDataDir = ConfigService.shared.relayDataDir
        enqueueLifecycle { [weak self] in
            guard let self else { return }
            guard !self.isVaultBusy, !self.isRunning, !self.isShuttingDown else {
                self.logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Locks not cleared: the vault is running or busy"))
                return
            }
            self.performClearDatabaseLocks(at: relayDataDir)
            self.isLocked = false
            self.needsLockFix = false
            self.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Database locks cleared."))
            await self.performStart(config: config, isRetry: true)
        }
    }

    func clearDatabaseLocks(completion: (@Sendable () -> Void)? = nil) {
        let relayDataDir = ConfigService.shared.relayDataDir
        Task {
            self.performClearDatabaseLocks(at: relayDataDir)
            await MainActor.run {
                self.isLocked = false
                self.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Database locks cleared."))
                completion?()
            }
        }
    }
    
    nonisolated func performClearDatabaseLocks(at relayDataDir: URL) {
        // Run synchronously to ensure locks are gone before we proceed with any new process
        let dbDir = relayDataDir.appendingPathComponent("data")
        
        // All known DB names (including blossom)
        let allDBs = ["chat", "inbox", "outbox", "private", "wot", "blossom"]
        let dbRoot = relayDataDir.appendingPathComponent("db")
        for name in allDBs {
            // Check data/NAME/LOCK
            removeLockFile(at: dbDir.appendingPathComponent(name).appendingPathComponent("LOCK"))
            // Check db/NAME/LOCK
            removeLockFile(at: dbRoot.appendingPathComponent(name).appendingPathComponent("LOCK"))
        }

        // Also check relayDataDir/blossom/LOCK (legacy path)
        removeLockFile(at: relayDataDir.appendingPathComponent("blossom").appendingPathComponent("LOCK"))
    }
    
    private nonisolated func removeLockFile(at url: URL) {
        // A LOCK a live process still holds (Badger flocks it; e.g. a Mac
        // Debug build on the same data) stays: deleting it let this start
        // open, and tidy rename, a store under that running relay (Tron S3
        // on #2045). A stale one from a crash has no holder and goes.
        guard !Self.lockHeldByLiveProcess(url.path) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                // We minimize MainActor hops here by not logging DEBUG info for every lock check
            } catch {
            }
        }
    }

    /// Whether a live process holds path's flock (Badger's directory lock).
    nonisolated static func lockHeldByLiveProcess(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }
}
