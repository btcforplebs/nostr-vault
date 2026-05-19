# Haven App Improvement Roadmap

## Context

Haven is a native macOS/iOS Nostr relay client at Build 5, targeting a small TestFlight beta group. The app is functional but needs polish, stability, and performance work before wider distribution. Priority areas: UI/UX refinements, performance, and stability for daily beta-tester use.

---

## Build 6 -- "Stability & Polish"

### Stability

1. **Relay lifecycle hardening** -- Add a 90-second watchdog timer for boot failures with auto-offer of "Force Restart". Add 5-second forced timeout to `stopRelay()` with state reset to `idle`.
   - File: `HavenApp/HavenApp/Services/RelayProcessManager.swift`

2. **WebSocket reconnection jitter** -- Add 0-2s random jitter to reconnection timers so multiple clients don't all reconnect simultaneously after a network drop. After 5 consecutive failures, mark relay as degraded and show indicator.
   - File: `HavenApp/HavenApp/Services/WebSocketClient.swift` (lines 62-297)

3. **Persist interaction state** -- Verify `likedEventIds` and `zappedEventIds` survive cold launches. If not, serialize to disk alongside `profiles.json`.
   - File: `HavenApp/HavenApp/Services/FeedService.swift`

4. **Error recovery UX** -- Replace status-message-only boot failures with actionable error sheets (Retry button, clear explanation of port conflict / lock file / WoT timeout).
   - File: `HavenApp/HavenApp/Views/DashboardView.swift`

### UI/UX Polish

5. **Loading state consistency** -- Add skeleton rows to NoteDetailView while replies load. Add shimmer animation to all skeleton views. Show inline loading indicator during `loadMore()`.

6. **Empty state improvements** -- Distinguish "relay booting" from "no follows" in empty feed. Add quick "Paste npub to follow" action in the empty state.

7. **Connection status refinement** -- Expand the feed status dot to three states: green (live), orange (reconnecting), red (disconnected). Add tap-to-see relay details.

8. **Navigation consistency** -- Unify macOS sheet-based note opening with a NavigationStack approach for proper back-navigation. Verify swipe-to-dismiss works from all ProfileView entry points.

### Code Quality

9. **Split WebSocketClient.swift** (2,095 lines) into three files:
   - `Services/WebSocketClient.swift` -- WebSocketClient + LocalhostTrustDelegate (~300 lines)
   - `Services/NostrService.swift` -- NostrService class (~1,250 lines)
   - `Services/MediaCacheService.swift` -- MediaCacheService class (~530 lines)

---

## Build 7 -- "Performance & Depth"

### Performance

10. **Feed memory management** -- Cap `notes` array at ~500 items. Implement either a sliding window or discard-on-scroll with "Load More" for older content.
    - File: `HavenApp/HavenApp/Services/FeedService.swift` (line 112)

11. **Profile cache optimization** -- Switch `@Published var profiles` to a non-published backing store with manual `objectWillChange.send()` only when visible profiles change, to avoid full feed SwiftUI diffs on every profile mutation.

12. **Media memory pressure** -- Implement NSCache-backed LRU for decoded images (~50MB cap). Generate video thumbnails to disk rather than holding in memory.

13. **WebSocket connection pooling** -- Create a `ConnectionPool` that reuses open connections for the same relay URL (currently FeedService, NoteDetailView, and ProfileView each create independent clients). Cap at 8 concurrent connections app-wide.

### UI/UX Depth

14. **Accessibility** -- Add VoiceOver labels to interactive elements, switch hardcoded font sizes to Dynamic Type, ensure 44pt tap targets on iOS.

15. **Keyboard shortcuts (macOS)** -- Cmd+N (compose), Cmd+R (refresh), arrow key navigation, Enter (open note), Escape (dismiss).

16. **Animation polish** -- Spring animation on "New Posts" button appearance, subtle fade-in for real-time notes, matched geometry for feed-to-detail transitions.

### Code Quality

17. **Split RelayProcessManager.swift** (1,602 lines) into:
    - `Services/RelayProcessManager.swift` -- State machine, start/stop (~400 lines)
    - `Services/RelayEnvironmentGenerator.swift` -- env dictionary generation (~300 lines)
    - `Services/RelayLogParser.swift` -- Log capture, stdout/stderr, pattern matching (~400 lines)
    - `Services/RelayMetrics.swift` -- Memory/CPU monitoring (~200 lines)

18. **Unit tests for pure logic** -- Add `HavenAppTests` target with tests for:
    - `FeedNote` model (isReply, parentEventId, mediaURLs)
    - `HavenConfig` Codable round-trip
    - `Bech32` encoding/decoding
    - `NIP49Service` encrypt/decrypt

---

## Build 8+ -- "Distribution"

### Distribution Readiness

19. **Code signing & TestFlight** -- Set up certificates, provisioning profiles, automatic signing, internal/external testing groups.

20. **Structured logging** -- Replace `#if DEBUG print(...)` with OSLog. Add breadcrumbs (last 20 user actions, relay state transitions) for crash diagnosis.

21. **Crash reporting** -- MetricKit or TelemetryDeck for privacy-respecting analytics.

### Advanced Performance

22. **Background App Refresh (iOS)** -- BGTaskScheduler for periodic relay sync. Show "Catching up..." on return from background.

23. **Instruments profiling pass** -- Time Profiler, Allocations, Network. Fix main-thread JSON parsing escapes and retain cycles in Combine sinks.

24. **Storage management** -- Periodic BadgerDB compaction, storage usage display in settings, auto-prune cached media older than N days.

### Feature Polish

25. **Offline mode** -- Serve cached feed when offline, show "Offline" banner, queue outgoing actions for later execution.

26. **Onboarding refinement** -- Progress indicators in setup wizard, "import from existing client" flow, contextual help for Nostr concepts.

---

## Verification

After implementing each build phase:
- Cold-launch the app and verify no flash of empty state before feed loads
- Kill network (airplane mode) and verify reconnection behavior and error UI
- Profile with Instruments (Allocations) to verify memory stays flat during extended feed scrolling
- Test on both macOS and iOS simulators for navigation consistency
- Verify persistent state (likes, zaps) survives app restart
