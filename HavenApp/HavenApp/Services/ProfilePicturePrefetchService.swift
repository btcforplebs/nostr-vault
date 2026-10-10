import Foundation
import Combine
import Network

@MainActor
class ProfilePicturePrefetchService {
    static let shared = ProfilePicturePrefetchService()

    private var cancellables = Set<AnyCancellable>()
    private var checkTimer: AnyCancellable?
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.haven.pfp-prefetch-monitor")
    private var isWiFi = false
    private var isRunning = false
    private var started = false

    private let lastPrefetchKey = "ProfilePicturePrefetchService.lastPrefetchDate"

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        guard ConfigService.shared.config.prefetchProfilePictures else { return }
        guard !ConfigService.shared.config.disableMediaCache else { return }

        started = true
        startNetworkMonitor()
        setupTimer()

        // React to the toggle being turned off
        ConfigService.shared.$config
            .map(\.prefetchProfilePictures)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled {
                    self.stop()
                }
            }
            .store(in: &cancellables)

        // Initial check after a brief delay to let contacts load
        Task {
            try? await Task.sleep(for: .seconds(5))
            self.checkAndRun()
        }
    }

    func stop() {
        checkTimer?.cancel()
        checkTimer = nil
        pathMonitor.cancel()
        cancellables.removeAll()
        isRunning = false
        started = false
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                #if os(macOS)
                self.isWiFi = path.status == .satisfied
                #else
                self.isWiFi = path.status == .satisfied && !path.usesInterfaceType(.cellular)
                #endif
                #if DEBUG
                print("ProfilePicturePrefetchService: Network changed - isWiFi=\(self.isWiFi)")
                #endif
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    // MARK: - Scheduling

    private func setupTimer() {
        checkTimer = Timer.publish(every: 3600, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkAndRun()
            }
    }

    private func checkAndRun() {
        guard ConfigService.shared.config.prefetchProfilePictures else { return }
        guard !ConfigService.shared.config.disableMediaCache else { return }
        guard isWiFi else {
            #if DEBUG
            print("ProfilePicturePrefetchService: Skipping - not on Wi-Fi")
            #endif
            return
        }
        guard !isRunning else { return }

        if let lastRun = UserDefaults.standard.object(forKey: lastPrefetchKey) as? Date {
            let elapsed = Date().timeIntervalSince(lastRun)
            guard elapsed >= 86400 else {
                #if DEBUG
                print("ProfilePicturePrefetchService: Skipping - last run \(Int(elapsed / 3600))h ago")
                #endif
                return
            }
        }

        prefetchAllAvatars()
    }

    // MARK: - Prefetch Logic

    private func prefetchAllAvatars() {
        isRunning = true
        let pubkeys = FeedService.shared.followedPubkeys

        guard !pubkeys.isEmpty else {
            #if DEBUG
            print("ProfilePicturePrefetchService: No followed pubkeys, skipping")
            #endif
            isRunning = false
            return
        }

        #if DEBUG
        print("ProfilePicturePrefetchService: Starting prefetch for \(pubkeys.count) followed accounts")
        #endif

        // Ensure profiles are fetched for any we don't have yet
        let missingProfiles = pubkeys.filter { NostrService.shared.profiles[$0] == nil }
        if !missingProfiles.isEmpty {
            NostrService.shared.fetchMissingProfiles(for: missingProfiles)
        }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            // Brief delay to allow profile metadata to arrive for missing profiles
            if !missingProfiles.isEmpty {
                try? await Task.sleep(for: .seconds(5))
            }

            let profiles = await NostrService.shared.profiles
            var urls: [URL] = []
            for pubkey in pubkeys {
                if let url = profiles[pubkey]?.pictureURL {
                    urls.append(url)
                }
            }

            // Filter to only uncached URLs
            let uncached = urls.filter { !AvatarImageCache.shared.hasSmallCopy(of: $0) }

            #if DEBUG
            print("ProfilePicturePrefetchService: \(urls.count) total URLs, \(uncached.count) uncached")
            #endif

            // Process in batches of 10
            let batchSize = 10
            for batchStart in stride(from: 0, to: uncached.count, by: batchSize) {
                // Re-check Wi-Fi between batches
                let stillWiFi = await self.isWiFi
                guard stillWiFi else {
                    #if DEBUG
                    print("ProfilePicturePrefetchService: Lost Wi-Fi, stopping prefetch")
                    #endif
                    break
                }

                let batchEnd = min(batchStart + batchSize, uncached.count)
                let batch = Array(uncached[batchStart..<batchEnd])

                await withTaskGroup(of: Void.self) { group in
                    for url in batch {
                        group.addTask {
                            // Keeps the small copy only, like an avatar on screen.
                            _ = await AvatarImageCache.shared.load(url: url)
                        }
                    }
                }

                // Brief pause between batches
                try? await Task.sleep(for: .milliseconds(500))
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(Date(), forKey: self.lastPrefetchKey)
                self.isRunning = false
                #if DEBUG
                print("ProfilePicturePrefetchService: Prefetch complete - processed \(uncached.count) avatars")
                #endif
            }
        }
    }
}
