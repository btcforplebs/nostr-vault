import SwiftUI
import Foundation

// MARK: - Data Processing Extension
// Background data processing logic extracted from ViewerView for the MediaGallery tab.

extension MediaGalleryView {

    // MARK: - Debounce

    /// Cancels any pending update task, increments the generation counter, waits 150ms,
    /// then calls `updateDisplayData()`. Rapid-fire triggers coalesce into a single update.
    func scheduleUpdateDisplayData() {
        updateTask?.cancel()
        updateGeneration += 1
        let gen = updateGeneration
        updateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, gen == updateGeneration else { return }
            updateDisplayData()
        }
    }

    // MARK: - Display Data Computation (Media Only)

    /// Computes the merged, filtered, and sorted media item list from blossom cache
    /// and nostr note media, then updates `displayMedia` on the main actor.
    func updateDisplayData() {
        let currentNoteMedia = nostrService.noteMedia
        let currentBlossom = blossomCache.items
        let owner = nostrService.activeHexPubkey
        let isOwnerBrowsing = (owner == nostrService.ownerHexPubkey)
        let whitelist = configService.whitelistedHexPubkeys
        let blacklist = configService.activeAccountBlockedHexPubkeys
        let currentFilter = contentFilter
        let currentLocationFilter = mediaLocationFilter
        let currentTypeFilter = mediaTypeFilter
        let currentSort = sortOption
        let currentMirrorHosts: Set<String> = Set(
            configService.config.activeBlossomMirrors.compactMap {
                URL(string: $0)?.host?.lowercased()
            }
        )
        let macRelayHttps = configService.config.macRelayHttpsURL
        let currentNotFound = MediaCacheService.shared.known404Set()
        let gen = updateGeneration

        #if DEBUG
        print("MediaGallery updateDisplayData: blossom=\(currentBlossom.count) noteMedia=\(currentNoteMedia.count) filter=\(currentFilter) source=\(mediaSourceFilter)")
        #endif

        Task.detached(priority: .userInitiated) {
            var latestItems: [String: MediaItem] = [:]

            let remoteItems = currentNoteMedia.filter { item in
                if let pk = item.pubkey, blacklist.contains(pk) { return false }

                switch currentFilter {
                case .all:
                    // The Blossom media tab shows YOUR OWN media only. noteMedia is built
                    // from all processed events — including inbox/tagged events authored by
                    // others — so anything broader than `pubkey == owner` leaks media from
                    // people who merely tag you into your gallery. (The old WoT branch +
                    // `return true` empty-WoT fallback did exactly that.) Discover/WoT media
                    // belongs in the media feed, not this tab.
                    return item.pubkey == owner
                case .mine: return item.pubkey == owner
                case .tagged:
                    return false
                case .whitelist:
                    guard let pk = item.pubkey else { return false }
                    return whitelist.contains(pk) && pk != owner
                }
            }

            // Build hash -> event timestamp lookup from ALL noteMedia (unfiltered)
            // so blossom items get correct dates even when no noteMedia match survives filtering
            var eventTimestamps: [String: Date] = [:]
            for item in currentNoteMedia {
                let key = self.normalizedKeyStatic(for: item.url)
                if let existing = eventTimestamps[key] {
                    if item.dateAdded > existing { eventTimestamps[key] = item.dateAdded }
                } else {
                    eventTimestamps[key] = item.dateAdded
                }
            }

            // Track every URL we've seen per hash so we can later prefer a mirror URL
            // for display (and for the Blossom/Cache/404 classification).
            var urlsByKey: [String: [URL]] = [:]
            let recordURL: (String, URL) -> Void = { key, url in
                var existing = urlsByKey[key] ?? []
                if !existing.contains(url) { existing.append(url) }
                urlsByKey[key] = existing
            }

            // Add blossom items first — they have accurate mime detection from local bytes + relay
            // Apply event timestamps where available instead of file modification dates
            if currentFilter == .all || currentFilter == .mine {
                for item in currentBlossom {
                    // Whitelisted accounts only see their own blossom items
                    if !isOwnerBrowsing && currentFilter == .all {
                        let isMine = item.pubkey == owner
                        if !isMine { continue }
                    }
                    // Owner sees only their OWN blossom items: drop media authored by
                    // others that was mirrored onto this Blossom server. Items with no
                    // known author (direct uploads) are kept.
                    if isOwnerBrowsing && currentFilter == .all {
                        if let pk = item.pubkey, pk != owner { continue }
                    }
                    let key = self.normalizedKeyStatic(for: item.url)
                    recordURL(key, item.url)
                    if let eventDate = eventTimestamps[key] {
                        latestItems[key] = MediaItem(
                            id: item.id,
                            url: item.url,
                            type: item.type,
                            dateAdded: eventDate,
                            pubkey: item.pubkey,
                            tags: item.tags,
                            mimeType: item.mimeType
                        )
                    } else {
                        latestItems[key] = item
                    }
                }
            }

            for item in remoteItems {
                let key = self.normalizedKeyStatic(for: item.url)
                recordURL(key, item.url)
                if let existing = latestItems[key] {
                    // Blossom item exists — keep its superior mime detection
                    // but use the nostr event's created_at as the authoritative date
                    latestItems[key] = MediaItem(
                        id: existing.id,
                        url: existing.url,
                        type: existing.type,
                        dateAdded: item.dateAdded,
                        pubkey: item.pubkey ?? existing.pubkey,
                        tags: item.tags ?? existing.tags,
                        mimeType: existing.mimeType ?? item.mimeType
                    )
                } else {
                    latestItems[key] = item
                }
            }

            // Promote each merged item to its best display URL.
            // Priority: known mirror URL > current URL > any other recorded URL.
            let mirrorHostsCapture = currentMirrorHosts
            let macHostCapture = URL(string: macRelayHttps)?.host?.lowercased()
            let isOnMirror: (URL) -> Bool = { url in
                guard let host = url.host?.lowercased() else { return false }
                if mirrorHostsCapture.contains(host) { return true }
                if host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0" { return true }
                if let macHost = macHostCapture, host == macHost { return true }
                return false
            }
            for (key, item) in latestItems {
                let candidates = urlsByKey[key] ?? [item.url]
                if !isOnMirror(item.url), let mirrorURL = candidates.first(where: isOnMirror) {
                    latestItems[key] = MediaItem(
                        id: item.id,
                        url: mirrorURL,
                        type: item.type,
                        dateAdded: item.dateAdded,
                        pubkey: item.pubkey,
                        tags: item.tags,
                        mimeType: item.mimeType
                    )
                }
            }

            // Merge and filter all items directly
            let allItems = Array(latestItems.values)
            let hasEventTimestamp = Set(eventTimestamps.keys)

            // Filter by media type
            let typeFilterSet = currentTypeFilter
            var filtered = allItems.filter { typeFilterSet.contains(MediaTypeFilter.category(of: $0)) }

            // Apply location filter: blossom (physically in local blossom directory) /
            // cache (cached from feed, not in blossom) / notFound (user-flagged 404) /
            // all (blossom+cache).
            let notFoundCapture = currentNotFound
            let locationFilter = currentLocationFilter

            // Resolve "is this actually in the local blossom directory" once per
            // item. It can hit the filesystem, and both the location filter and
            // the on-relay-first sort need the answer.
            var inBlossomByKey: [String: Bool] = [:]
            for item in filtered {
                let hash = self.normalizedKeyStatic(for: item.url)
                if inBlossomByKey[hash] == nil {
                    inBlossomByKey[hash] = MediaCacheService.shared.isInLocalBlossom(hash: hash)
                }
            }
            let inBlossomLookup = inBlossomByKey

            let passesLocation: (MediaItem) -> Bool = { item in
                let is404 = notFoundCapture.contains(item.url.absoluteString)
                let hash = self.normalizedKeyStatic(for: item.url)
                let inBlossomDir = inBlossomLookup[hash] ?? false

                switch locationFilter {
                case .all: return !is404
                case .blossom: return inBlossomDir && !is404
                case .cache: return !inBlossomDir && !is404
                case .notFound: return is404
                }
            }
            filtered = filtered.filter(passesLocation)

            // Exclude items from notes that merely tag the owner —
            // these are often spam and not user-uploaded media.
            filtered = filtered.filter { item in
                if item.pubkey == owner { return true }
                let tagsOwner = item.tags?.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == owner } ?? false
                return !tagsOwner
            }

            filtered = currentSort.sorted(filtered) {
                inBlossomLookup[self.normalizedKeyStatic(for: $0.url)] ?? false
            }
            var result = filtered

            #if DEBUG
            let timestampCount = eventTimestamps.count
            let blossomWithTimestamp = currentBlossom.filter { hasEventTimestamp.contains(self.normalizedKeyStatic(for: $0.url)) }.count
            let timestampedCount = allItems.filter { hasEventTimestamp.contains(self.normalizedKeyStatic(for: $0.url)) || !self.isLocalBlossomURL($0.url) }.count
            let unmatchedCount = allItems.count - timestampedCount
            print("MediaGallery updateDisplayData: eventTimestamps=\(timestampCount) blossomMatched=\(blossomWithTimestamp)/\(currentBlossom.count) timestamped=\(timestampedCount) unmatched=\(unmatchedCount)")
            if let first = result.first {
                let df = DateFormatter()
                df.dateFormat = "MM/dd HH:mm"
                print("  first: \(df.string(from: first.dateAdded)) url=\(first.url.lastPathComponent.prefix(12))")
            }
            #endif

            // Fix up items with missing or octet-stream mime types by sniffing extension
            for i in result.indices {
                let item = result[i]
                let needsSniff = item.type == .unknown ||
                    (item.mimeType == nil && item.url.pathExtension.isEmpty) ||
                    item.mimeType?.lowercased() == "application/octet-stream"
                if needsSniff {
                    let ext = item.url.pathExtension.lowercased()
                    var sniffedType: MediaItem.MediaType = .unknown
                    var sniffedMime: String? = nil

                    if let mime = SupportedMediaFormats.mime(forExtension: ext) {
                        switch SupportedMediaFormats.category(forExtension: ext) {
                        case .image, .gif: sniffedType = .image
                        case .video:       sniffedType = .video
                        case .audio:       sniffedType = .audio
                        case .none:        break
                        }
                        sniffedMime = mime
                    }

                    if sniffedType != .unknown {
                        result[i] = MediaItem(id: item.id, url: item.url, type: sniffedType, dateAdded: item.dateAdded, pubkey: item.pubkey, tags: item.tags, mimeType: sniffedMime)
                    }
                }
            }

            let finalResult = result

            // Skip UI update if a newer generation has been triggered
            guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }

            await MainActor.run {
                self.displayMedia = Array(finalResult.prefix(self.maxDisplayedItems))
                self.mediaHasLoadedOnce = true
            }
        }
    }

    // MARK: - Sorting Helpers

    /// Ordering used by the "Media type" sort: photos, then GIFs, then video,
    /// then everything else.
    nonisolated static func typeRank(for item: MediaItem) -> Int {
        if item.isAnimatedGIF { return 1 }
        switch item.type {
        case .image:   return 0
        case .video:   return 2
        case .audio:   return 3
        case .unknown: return 4
        }
    }

    // MARK: - URL Helpers

    /// Checks if URL points to the local blossom server (127.0.0.1, localhost, or 0.0.0.0).
    nonisolated func isLocalBlossomURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0"
    }

    /// Normalizes a media URL to a dedup key by extracting the sha256 hash.
    /// Falls back to the filename (sans extension) when no 64-char hex is found.
    nonisolated func normalizedKeyStatic(for url: URL) -> String {
        let urlString = url.absoluteString
        let lastComponent = url.lastPathComponent
        if lastComponent.count == 64 && lastComponent.allSatisfy({ $0.isHexDigit }) {
            return lastComponent
        }
        if let match = Self.hexPattern.firstMatch(in: urlString, options: [], range: NSRange(urlString.startIndex..., in: urlString)),
           let range = Range(match.range, in: urlString) {
            return String(urlString[range])
        }
        return url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Local Media Loading

    /// Scans the local blossom directory for media items and updates `blossomCache`.
    /// Also starts the filesystem watcher for external uploads.
    func loadLocalMedia(force: Bool = false) {
        let cache = blossomCache

        // Start filesystem watcher so external uploads (e.g. phone -> Mac relay) trigger a rescan
        let blossomDir = configService.relayDataDir.appendingPathComponent(configService.config.blossomPath)
        cache.startWatchingIfNeeded(directory: blossomDir)

        // Skip rescan if cache is fresh and this isn't a forced reload (e.g. after upload/delete)
        if !force && cache.isFresh() { return }

        // Concurrency guard
        if cache.isScanning { return }

        // Only load if relay is ready
        guard relayManager.isRunning && !relayManager.isBooting else {
            #if DEBUG
            print("MediaGallery: Skipping media load - relay not ready")
            #endif
            cache.items = []
            return
        }

        cache.isScanning = true

        Task {
            let relayDataDir = configService.relayDataDir
            let blossomPath = configService.config.blossomPath
            let ownerHex = nostrService.activeHexPubkey
            let webURL = configService.config.webURL
            let rpm = relayManager

            let result = await Task.detached(priority: .background) { () -> [MediaItem] in
                let blossomDir = relayDataDir.appendingPathComponent(blossomPath)
                if !FileManager.default.fileExists(atPath: blossomDir.path) {
                    try? FileManager.default.createDirectory(at: blossomDir, withIntermediateDirectories: true)
                    return []
                }

                guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: blossomDir, includingPropertiesForKeys: [.creationDateKey]) else {
                    return []
                }

                return fileURLs.compactMap { fileURL -> MediaItem? in
                    let filename = fileURL.lastPathComponent
                    if filename.starts(with: ".") || filename == "LOCK" { return nil }
                    guard let serveURL = URL(string: "\(webURL)/\(filename)") else { return nil }

                    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let date = (attributes?[.modificationDate] as? Date) ?? (attributes?[.creationDate] as? Date) ?? Date()

                    // Same detection pipeline as blossom export: proof (bytes) + claim (relay) -> resolve
                    let proof = rpm.detectMimeFromBytes(for: fileURL)
                    let resolvedMime = rpm.resolveMime(claim: nil, proof: proof)
                    let mimeType = resolvedMime == "application/octet-stream" ? nil : resolvedMime

                    let mediaType: MediaItem.MediaType
                    if let mime = mimeType {
                        if mime.hasPrefix("video/") { mediaType = .video }
                        else if mime.hasPrefix("audio/") { mediaType = .audio }
                        else if mime.hasPrefix("image/") { mediaType = .image }
                        else { mediaType = .unknown }
                    } else {
                        mediaType = .unknown
                    }

                    return MediaItem(id: UUID(), url: serveURL, type: mediaType, dateAdded: date, pubkey: ownerHex, tags: nil, mimeType: mimeType)
                }
            }.value

            await MainActor.run {
                if cache.items.count != result.count {
                    #if DEBUG
                    print("MediaGallery: Loaded \(result.count) Blossom media items")
                    #endif
                }
                cache.items = result
                cache.lastScanDate = Date()
                cache.isScanning = false
            }
        }
    }

    // MARK: - Refresh

    /// Full refresh for the media gallery tab. Resets connections, re-fetches notes,
    /// reloads local media, and schedules a display update.
    func refreshAll() {
        guard relayManager.isRunning && !relayManager.isBooting else {
            #if DEBUG
            print("MediaGallery: Skipping refresh - relay not ready")
            #endif
            return
        }

        // Debounce: cancel any pending refresh and wait 0.5s before executing.
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }

            nostrService.resetConnections()

            var urls = [configService.config.nostrURL, configService.config.nostrURL + "/inbox"].compactMap { URL(string: $0) }

            // Also query the Mac relay for tagged notes the local relay may
            // not have (e.g. due to shorter WoT depth or notes missed while suspended).
            let macURL = configService.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !macURL.isEmpty {
                if let macRelay = URL(string: macURL) { urls.append(macRelay) }
                if let macInbox = URL(string: macURL + "/inbox") { urls.append(macInbox) }
            }

            var authorsSet = Set<String>()
            if let ownerHex = Bech32.decode(configService.config.ownerNpub)?.hexString {
                authorsSet.insert(ownerHex)
            }
            for pk in configService.whitelistedHexPubkeys { authorsSet.insert(pk) }
            let authors = Array(authorsSet)

            nostrService.fetchNotes(from: urls, authors: authors)
            loadLocalMedia(force: true)
            scheduleUpdateDisplayData()
        }
    }

    // MARK: - Pagination

    /// Increments the visible item cap by 50 and triggers a display data recomputation.
    func loadMoreItems() {
        maxDisplayedItems += 50
        scheduleUpdateDisplayData()
    }
}
