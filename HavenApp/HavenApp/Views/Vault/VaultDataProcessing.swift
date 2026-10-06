import SwiftUI

extension VaultView {

    // MARK: - Background Processing

    func scheduleUpdateDisplayData() {
        updateTask?.cancel()
        updateGeneration += 1
        let gen = updateGeneration
        updateTask = Task { @MainActor in
            // Debounce: wait 150ms so rapid-fire triggers coalesce into one update
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, gen == updateGeneration else { return }
            updateDisplayData()
        }
    }

    // MARK: - New Event Notification Tracking

    /// Snapshot current event kind counts as the notification baseline.
    /// Called after initial data settles and when the user views a tab.
    func establishNotificationBaseline() {
        var counts: [Int: Int] = [:]
        for event in nostrService.events {
            counts[event.kind, default: 0] += 1
        }
        notificationBaseline = counts
        hasEstablishedNotificationBaseline = true
    }

    /// Check if new events arrived for categories the user isn't currently viewing.
    func checkForNewNotifications() {
        guard hasEstablishedNotificationBaseline else { return }

        var counts: [Int: Int] = [:]
        for event in nostrService.events {
            counts[event.kind, default: 0] += 1
        }

        // Notes: NostrService.relayTabNoteKinds
        let noteKinds = NostrService.relayTabNoteKinds
        let noteCount = noteKinds.reduce(0) { $0 + (counts[$1] ?? 0) }
        let baselineNotes = noteKinds.reduce(0) { $0 + (notificationBaseline[$1] ?? 0) }
        if noteCount > baselineNotes && viewMode != .notes {
            withAnimation(Motion.fade) { hasNewNotes = true }
        }

        // Likes: kind 7 — suppressed in Zaps Only mode (likes are hidden from the UI)
        if !configService.config.zapsOnlyMode
            && (counts[7] ?? 0) > (notificationBaseline[7] ?? 0) && viewMode != .likes {
            withAnimation(Motion.fade) { hasNewLikes = true }
        }

        // Zaps: kind 9735
        if (counts[9735] ?? 0) > (notificationBaseline[9735] ?? 0) && viewMode != .zaps {
            withAnimation(Motion.fade) { hasNewZaps = true }
        }
    }

    /// Clear the notification flag for the given tab and update its baseline.
    func markTabViewed(_ mode: ViewMode) {
        let events = nostrService.events
        switch mode {
        case .notes:
            if hasNewNotes {
                withAnimation(Motion.fade) { hasNewNotes = false }
            }
            for kind in NostrService.relayTabNoteKinds {
                notificationBaseline[kind] = events.filter { $0.kind == kind }.count
            }
        case .likes:
            if hasNewLikes {
                withAnimation(Motion.fade) { hasNewLikes = false }
            }
            notificationBaseline[7] = events.filter { $0.kind == 7 }.count
        case .zaps:
            if hasNewZaps {
                withAnimation(Motion.fade) { hasNewZaps = false }
            }
            notificationBaseline[9735] = events.filter { $0.kind == 9735 }.count
        case .followers:
            markFollowersSeen()
        case .media:
            break
        }
    }

    /// Flips `likesInitialSettled` to true once fetching has been quiet for ~1.5s
    /// while in likes mode. Lets the empty state appear without flashing the
    /// spinner on every transient `isFetching` toggle.
    func updateLikesSettleState() {
        likesSettleTask?.cancel()
        let busy = nostrService.isFetching || relayManager.isBooting
        if busy {
            likesInitialSettled = false
            // Fallback: settle after 5s even if still fetching, so the
            // spinner doesn't stay forever when a relay never sends EOSE.
            likesSettleTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                likesInitialSettled = true
            }
            return
        }
        likesSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            if !(nostrService.isFetching || relayManager.isBooting) {
                likesInitialSettled = true
            }
        }
    }

    func updateZapsSettleState() {
        // Already settled, or a settle run is already in flight. Crucially we do
        // NOT cancel/restart on every isFetching toggle — that churn is exactly
        // what kept the spinner up forever (the fallback timer never fired).
        if zapsInitialSettled || zapsSettleTask != nil { return }
        zapsSettleTask = Task { @MainActor in
            let step: UInt64 = 500_000_000        // 0.5s poll
            let hardCap: UInt64 = 6_000_000_000   // settle within 6s no matter what
            let quietTarget: UInt64 = 1_000_000_000 // …or as soon as fetching is quiet for 1s
            var elapsed: UInt64 = 0
            var quiet: UInt64 = 0
            while elapsed < hardCap {
                try? await Task.sleep(nanoseconds: step)
                if Task.isCancelled { zapsSettleTask = nil; return }
                elapsed += step
                if nostrService.isFetching || relayManager.isBooting || walletGivenLoading {
                    quiet = 0
                } else {
                    quiet += step
                    if quiet >= quietTarget { break }
                }
            }
            zapsInitialSettled = true
            zapsSettleTask = nil
        }
    }

    // MARK: - Search Filter

    nonisolated static func applySearchFilter(
        to events: [NostrEvent],
        search: String,
        scope: SearchScope
    ) -> [NostrEvent] {
        guard !search.isEmpty else { return events }
        switch scope {
        case .notes:
            return events.filter {
                $0.content.localizedCaseInsensitiveContains(search)
            }
        case .hashtags:
            let normalizedQuery = search
                .lowercased()
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "#", with: "")
            return events.filter { event in
                event.tags.contains { tag in
                    tag.count >= 2
                        && tag[0] == "t"
                        && tag[1].lowercased().contains(normalizedQuery)
                }
            }
        case .profiles:
            return events
        }
    }

    // MARK: - Update Display Data

    func updateDisplayData() {
        // Capture current state strongly for the background task
        let currentFilter = contentFilter
        let currentSearch = committedSearch
        let currentScope = searchScope
        let currentEvents = nostrService.events
        let owner = nostrService.activeHexPubkey
        let whitelist = configService.whitelistedHexPubkeys
        let blacklist = configService.activeAccountBlockedHexPubkeys
        let trusted = FeedService.shared.relayTabTrustedPubkeys()

        #if DEBUG
        print("updateDisplayData: events=\(currentEvents.count) filter=\(currentFilter)")
        #endif
        let currentMode = viewMode
        let currentLikesFilter = likesFilter
        let currentZapsFilter = zapsFilter
        let walletGiven = walletGivenNotes
        let walletGivenSats = walletGivenAmounts
        let walletGivenAt = walletGivenTimes
        let locallyZapped = FeedService.shared.zappedEventIds
        let currentMaxDisplayed = maxDisplayedItems
        let gen = updateGeneration

        Task.detached(priority: .userInitiated) {
            if currentMode == .likes {
                // MARK: - Likes Mode
                let noteKinds = NostrService.relayTabNoteKinds

                if currentLikesFilter == .myLikes {
                    // My Likes: notes I reacted to (kind 7 from me)
                    var myLikeDates: [String: Date] = [:]
                    for event in currentEvents where event.kind == 7 && event.pubkey == owner {
                        if let targetId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                            if let existing = myLikeDates[targetId] {
                                if event.createdAtDate > existing { myLikeDates[targetId] = event.createdAtDate }
                            } else {
                                myLikeDates[targetId] = event.createdAtDate
                            }
                        }
                    }
                    let myLikedNoteIds = Set(myLikeDates.keys)
                    var filtered = currentEvents.filter { noteKinds.contains($0.kind) && myLikedNoteIds.contains($0.id) }
                    filtered.sort { (myLikeDates[$0.id] ?? Date.distantPast) > (myLikeDates[$1.id] ?? Date.distantPast) }

                    let result = Self.applySearchFilter(to: filtered, search: currentSearch, scope: currentScope)

                    guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                    await MainActor.run {
                        let newDisplay = Array(result.prefix(self.maxDisplayedItems))
                        if self.displayLikedNotes.map({ $0.id }) != newDisplay.map({ $0.id }) {
                            self.displayLikedNotes = newDisplay
                        }
                        if !self.reactionMap.isEmpty { self.reactionMap = [:] }
                        if !newDisplay.isEmpty { self.likesHasLoadedOnce = true }
                    }
                } else {
                    // Incoming reactions: determine target note set based on filter
                    let targetNoteIds: Set<String>
                    switch currentLikesFilter {
                    case .onMyNotes:
                        targetNoteIds = Set(currentEvents.filter { $0.pubkey == owner && noteKinds.contains($0.kind) }.map { $0.id })
                    case .myLikes:
                        targetNoteIds = [] // handled above
                    }

                    // Build reaction map: noteId -> [(pubkey, emoji)] + track newest reaction time per note
                    var rxMap: [String: [(pubkey: String, emoji: String)]] = [:]
                    var latestReaction: [String: Date] = [:]
                    let excludeSelf = (currentLikesFilter == .onMyNotes)
                    for event in currentEvents where event.kind == 7 {
                        if excludeSelf && event.pubkey == owner { continue }
                        if let targetId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" && targetNoteIds.contains($0[1]) })?[1] {
                            let emoji = event.content.isEmpty ? "+" : event.content
                            rxMap[targetId, default: []].append((pubkey: event.pubkey, emoji: emoji))
                            let d = event.createdAtDate
                            if let existing = latestReaction[targetId] {
                                if d > existing { latestReaction[targetId] = d }
                            } else {
                                latestReaction[targetId] = d
                            }
                        }
                    }

                    let likedNoteIds = Set(rxMap.keys)
                    var filtered = currentEvents.filter { noteKinds.contains($0.kind) && likedNoteIds.contains($0.id) }
                    // Sort by newest reaction first, tiebreaking by note date
                    filtered.sort {
                        let d0 = latestReaction[$0.id] ?? Date.distantPast
                        let d1 = latestReaction[$1.id] ?? Date.distantPast
                        if d0 == d1 { return $0.createdAtDate > $1.createdAtDate }
                        return d0 > d1
                    }

                    let result = Self.applySearchFilter(to: filtered, search: currentSearch, scope: currentScope)

                    let finalRxMap = rxMap
                    let finalReactionDates = latestReaction
                    guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                    await MainActor.run {
                        let newDisplay = Array(result.prefix(self.maxDisplayedItems))
                        if self.displayLikedNotes.map({ $0.id }) != newDisplay.map({ $0.id }) {
                            self.displayLikedNotes = newDisplay
                        }
                        self.reactionMap = finalRxMap
                        self.latestReactionDates = finalReactionDates
                        if !newDisplay.isEmpty { self.likesHasLoadedOnce = true }
                    }
                }
            } else if currentMode == .zaps {
                // MARK: - Zaps Mode (cached parsing)
                let noteKinds = NostrService.relayTabNoteKinds
                let zapReceipts = currentEvents.filter { $0.kind == 9735 }
                // Both lists run newest zap first: a post moves to the top
                // when a zap on it comes in.
                let receiptTimes = Dictionary(zapReceipts.map { ($0.id, $0.created_at) }, uniquingKeysWith: { a, _ in a })

                // Parse all zap receipts, using cache for already-parsed ones
                let existingCache = await MainActor.run { self.zapReceiptCache }
                var newCacheEntries: [String: ParsedZapReceipt] = [:]
                var parsedReceipts: [(receiptId: String, parsed: ParsedZapReceipt)] = []
                parsedReceipts.reserveCapacity(zapReceipts.count)

                for receipt in zapReceipts {
                    if let cached = existingCache[receipt.id] {
                        parsedReceipts.append((receipt.id, cached))
                    } else {
                        guard let descJson = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
                              let descData = descJson.data(using: .utf8),
                              let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
                              let senderPubkey = zapReq["pubkey"] as? String else { continue }
                        // The note comes from the signed request, not the receipt: a forged
                        // receipt can wrap your real request and point it at another note.
                        let requestTargetId = (zapReq["tags"] as? [[String]])?.first(where: { $0.count >= 2 && $0[0] == "e" })?[1]
                        let targetId = requestTargetId ?? receipt.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1]
                        // The request's `amount` tag is optional (NIP-57); the paid invoice is not.
                        let amountSats = Int64(LiveChat.zapAmountSats(receiptTags: receipt.tags,
                                                                         requestTags: zapReq["tags"] as? [[String]] ?? []))
                        let parsed = ParsedZapReceipt(senderPubkey: senderPubkey, targetNoteId: targetId, amountSats: amountSats,
                                                      requestIsSigned: NostrEventVerifier.isValid(json: descJson))
                        newCacheEntries[receipt.id] = parsed
                        parsedReceipts.append((receipt.id, parsed))
                    }
                }

                if !newCacheEntries.isEmpty {
                    let entries = newCacheEntries
                    await MainActor.run {
                        for (key, value) in entries {
                            self.zapReceiptCache[key] = value
                        }
                    }
                }

                if currentZapsFilter == .myZaps {
                    // My Zaps: notes I zapped
                    var myZappedNoteIds = Set(parsedReceipts.compactMap { item -> String? in
                        guard item.parsed.senderPubkey == owner, item.parsed.requestIsSigned else { return nil }
                        return item.parsed.targetNoteId
                    })
                    // …and what this app recorded zapping from this phone.
                    myZappedNoteIds.formUnion(locallyZapped.keys)
                    // The wallet's history, then anything only a receipt on
                    // the relays or this app's own list knows about.
                    var seen = Set(walletGiven.map(\.id))
                    var filtered = walletGiven
                    filtered += currentEvents.filter {
                        noteKinds.contains($0.kind) && myZappedNoteIds.contains($0.id) && seen.insert($0.id).inserted
                    }
                    var lastZapAt = walletGivenAt
                    for item in parsedReceipts where item.parsed.senderPubkey == owner && item.parsed.requestIsSigned {
                        guard let id = item.parsed.targetNoteId, let at = receiptTimes[item.receiptId] else { continue }
                        lastZapAt[id] = max(lastZapAt[id] ?? 0, at)
                    }
                    // A zap only this app recorded has no time: the post's own stands in.
                    filtered.sort { a, b in
                        let ta = lastZapAt[a.id] ?? a.created_at, tb = lastZapAt[b.id] ?? b.created_at
                        return ta != tb ? ta > tb : a.created_at > b.created_at
                    }
                    var givenMap: [String: [(pubkey: String, amount: Int64)]] = [:]
                    for (id, sats) in locallyZapped where sats > 0 { givenMap[id] = [(pubkey: owner, amount: Int64(sats))] }
                    for (id, sats) in walletGivenSats { givenMap[id] = [(pubkey: owner, amount: sats)] }

                    let result = Self.applySearchFilter(to: filtered, search: currentSearch, scope: currentScope)
                    let finalGivenMap = givenMap

                    guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                    await MainActor.run {
                        let newDisplay = Array(result.prefix(self.maxDisplayedItems))
                        if self.displayZappedNotes.map({ $0.id }) != newDisplay.map({ $0.id }) {
                            self.displayZappedNotes = newDisplay
                        }
                        self.zapMap = finalGivenMap
                        if !newDisplay.isEmpty { self.zapsHasLoadedOnce = true }
                    }
                } else {
                    // Incoming zaps: determine target note set based on filter
                    let targetNoteIds: Set<String>
                    switch currentZapsFilter {
                    case .onMyNotes:
                        targetNoteIds = Set(currentEvents.filter { $0.pubkey == owner && noteKinds.contains($0.kind) }.map { $0.id })
                    case .myZaps:
                        targetNoteIds = [] // handled above
                    }

                    let excludeSelf = (currentZapsFilter == .onMyNotes)
                    var zMap: [String: [(pubkey: String, amount: Int64)]] = [:]
                    var lastZapAt: [String: Int64] = [:]
                    for item in parsedReceipts {
                        guard let targetId = item.parsed.targetNoteId,
                              targetNoteIds.contains(targetId) else { continue }
                        if excludeSelf && item.parsed.senderPubkey == owner { continue }
                        zMap[targetId, default: []].append((pubkey: item.parsed.senderPubkey, amount: item.parsed.amountSats))
                        lastZapAt[targetId] = max(lastZapAt[targetId] ?? 0, receiptTimes[item.receiptId] ?? 0)
                    }

                    let zappedNoteIds = Set(zMap.keys)
                    var filtered = currentEvents.filter { noteKinds.contains($0.kind) && zappedNoteIds.contains($0.id) }
                    filtered.sort { a, b in
                        let ta = lastZapAt[a.id] ?? 0, tb = lastZapAt[b.id] ?? 0
                        return ta != tb ? ta > tb : a.created_at > b.created_at
                    }

                    let result = Self.applySearchFilter(to: filtered, search: currentSearch, scope: currentScope)

                    let finalZMap = zMap
                    guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                    await MainActor.run {
                        let newDisplay = Array(result.prefix(self.maxDisplayedItems))
                        if self.displayZappedNotes.map({ $0.id }) != newDisplay.map({ $0.id }) {
                            self.displayZappedNotes = newDisplay
                        }
                        self.zapMap = finalZMap
                        if !newDisplay.isEmpty { self.zapsHasLoadedOnce = true }
                    }
                }
            } else if currentMode == .notes {
                // MARK: - Notes Mode (NostrService.relayTabNoteKinds)
                let filtered = currentEvents.filter { event in
                    let validKinds = NostrService.relayTabNoteKinds
                    if !validKinds.contains(event.kind) { return false }

                    if blacklist.contains(event.pubkey) { return false }

                    let isMine = event.pubkey == owner
                    let isTagged = event.tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == owner }
                    let isWhitelisted = whitelist.contains(event.pubkey)
                    let isOutside = isTagged && ContentFilter.isOutside(
                        author: event.pubkey, owner: owner, whitelist: whitelist, trusted: trusted)
                    switch currentFilter {
                    case .all:
                        return (isMine || isTagged || isWhitelisted) && !isOutside
                    case .mine: return isMine
                    case .tagged: return !isMine && isTagged && !isOutside
                    case .whitelist:
                        return isWhitelisted && !isMine
                    case .outside: return isOutside
                    }
                }

                // A repost is a second card for a post: when the original is
                // listed with its engagement bar, the repost is already counted
                // there, so drop the card. Several reposts of the same note
                // that isn't listed collapse to the newest one.
                let listedWithEngagement = Set(filtered.lazy
                    .filter { $0.kind != 6 && ($0.pubkey == owner || whitelist.contains($0.pubkey)) }
                    .map(\.id))
                var repostTargetsShown = Set<String>()
                // Events arrive newest first, so the first repost kept is the newest.
                let deduped = filtered.filter { event in
                    guard event.kind == 6,
                          let target = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1]
                    else { return true }
                    if listedWithEngagement.contains(target) { return false }
                    return repostTargetsShown.insert(target).inserted
                }

                let result = Self.applySearchFilter(to: deduped, search: currentSearch, scope: currentScope)

                // Compute engagement data (reactions & zaps) for all displayed notes
                let displaySlice = Array(result.prefix(currentMaxDisplayed))
                let displayedIds = Set(displaySlice.map { $0.id })

                var rxMap: [String: [(pubkey: String, emoji: String)]] = [:]
                var latestReaction: [String: Date] = [:]
                if !displayedIds.isEmpty {
                    for event in currentEvents where event.kind == 7 {
                        if let targetId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" && displayedIds.contains($0[1]) })?[1] {
                            let emoji = event.content.isEmpty ? "+" : event.content
                            rxMap[targetId, default: []].append((pubkey: event.pubkey, emoji: emoji))
                            let d = event.createdAtDate
                            if let existing = latestReaction[targetId] {
                                if d > existing { latestReaction[targetId] = d }
                            } else {
                                latestReaction[targetId] = d
                            }
                        }
                    }
                }

                var zMap: [String: [(pubkey: String, amount: Int64)]] = [:]
                if !displayedIds.isEmpty {
                    let zapReceipts = currentEvents.filter { $0.kind == 9735 }
                    for receipt in zapReceipts {
                        guard let targetId = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1],
                              displayedIds.contains(targetId) else { continue }
                        guard let descJson = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
                              let descData = descJson.data(using: .utf8),
                              let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
                              let senderPubkey = zapReq["pubkey"] as? String else { continue }
                        // The request's `amount` tag is optional (NIP-57); the paid invoice is not.
                        let amountSats = Int64(LiveChat.zapAmountSats(receiptTags: receipt.tags,
                                                                         requestTags: zapReq["tags"] as? [[String]] ?? []))
                        zMap[targetId, default: []].append((pubkey: senderPubkey, amount: amountSats))
                    }
                }

                // Repost map: noteId -> [reposter pubkeys]
                var rpMap: [String: [String]] = [:]
                if !displayedIds.isEmpty {
                    for event in currentEvents where event.kind == 6 {
                        if let targetId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" && displayedIds.contains($0[1]) })?[1] {
                            rpMap[targetId, default: []].append(event.pubkey)
                        }
                    }
                }

                // Quote map: noteId -> [quoter pubkeys]
                var qtMap: [String: [String]] = [:]
                if !displayedIds.isEmpty {
                    for event in currentEvents where event.kind == 1 {
                        if let targetId = event.tags.first(where: { $0.count >= 2 && $0[0] == "q" && displayedIds.contains($0[1]) })?[1] {
                            qtMap[targetId, default: []].append(event.pubkey)
                        }
                    }
                }

                let finalRxMap = rxMap
                let finalReactionDates = latestReaction
                let finalZMap = zMap
                let finalRpMap = rpMap
                let finalQtMap = qtMap

                // Skip UI update if a newer generation has been triggered
                guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }

                await MainActor.run {
                    self.displayNotes = displaySlice
                    self.reactionMap = finalRxMap
                    self.latestReactionDates = finalReactionDates
                    self.zapMap = finalZMap
                    self.repostMap = finalRpMap
                    self.quoteMap = finalQtMap
                    self.notesHasLoadedOnce = true
                }
            }

            // Profile search (independent of view mode)
            if currentScope == .profiles && !currentSearch.isEmpty {
                let allProfiles = await MainActor.run { Array(self.nostrService.profiles.values) }
                let query = currentSearch.lowercased()
                let matched = allProfiles.filter { profile in
                    (profile.name?.lowercased().contains(query) ?? false)
                    || (profile.displayName?.lowercased().contains(query) ?? false)
                    || (profile.nip05?.lowercased().contains(query) ?? false)
                    || (profile.about?.lowercased().contains(query) ?? false)
                }
                let sorted = matched.sorted { a, b in
                    let aName = a.bestName.lowercased()
                    let bName = b.bestName.lowercased()
                    let aPrefix = aName.hasPrefix(query)
                    let bPrefix = bName.hasPrefix(query)
                    if aPrefix != bPrefix { return aPrefix }
                    return aName < bName
                }
                let profileSlice = Array(sorted.prefix(50))
                guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                await MainActor.run {
                    self.displayProfileResults = profileSlice
                }
            } else {
                guard await MainActor.run(body: { gen == self.updateGeneration }) else { return }
                await MainActor.run {
                    if !self.displayProfileResults.isEmpty {
                        self.displayProfileResults = []
                    }
                }
            }
        }
    }

    // MARK: - Computed Properties

    var viewModeTitle: String {
        switch viewMode {
        case .notes: return "Notes"
        case .media: return "Media"
        case .likes: return "Likes"
        case .zaps: return "Zaps"
        case .followers: return "Followers"
        }
    }
}
