import Foundation
import Combine
import SwiftUI

// MARK: - Local Relay Search Session

/// Walks every local relay route to exhaustion for one query.
///
/// One socket per route, two paged subscriptions per socket (kind 1 notes and
/// kind 0 profiles). A page finishes on its own EOSE, and the whole search
/// finishes as soon as the last subscription is done — the timeout is only
/// there for a socket that never answers.
final class LocalRelaySearchSession {
    /// Fallback for a route that never connects or never EOSEs. Not the normal
    /// completion path: on-box LMDB answers a page in milliseconds.
    static let timeout: TimeInterval = 6.0

    private struct Stream {
        let routeIndex: Int
        let kind: Int
        var page: Int
        /// The cursor this page was asked with, so a full page stuck on one
        /// second can be stepped past (see `LocalRelaySearchPlan.step`).
        var until: Int64? = nil
    }

    /// How a finished session went, for Global search's per-source status.
    struct Outcome: Equatable {
        /// At least one route answered a page (EOSE).
        var answered: Bool
        /// Why nothing answered, when nothing did.
        var reason: String?
    }

    private let queue = DispatchQueue(label: "com.haven.local-relay-search")
    private let collector: LocalRelaySearchCollector
    private let routes: [URL]
    private let timeout: TimeInterval
    private let onFinish: (GlobalSearchResults) -> Void

    /// Called on the session's queue with the matches so far after every page,
    /// so a slow walk (the Mac relay over the network) can show results before
    /// it ends. Set before `start()`.
    var onProgress: ((GlobalSearchResults) -> Void)?
    /// Called on the session's queue just before `onFinish`. Set before `start()`.
    var onOutcome: ((Outcome) -> Void)?

    private var answeredRoutes = Set<Int>()
    private var failureReason: String?

    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()
    private var streams: [String: Stream] = [:]
    /// In-flight subscriptions per route. A route with no entry has not opened
    /// its streams yet — which is not the same as being finished, and treating
    /// the two alike would end the search as soon as the FIRST route drained.
    private var activeByRoute: [Int: Int] = [:]
    private var doneRoutes = Set<Int>()
    private var didFinish = false
    private var didStart = false

    init(matcher: LocalSearchMatcher,
         routes: [URL],
         timeout: TimeInterval = LocalRelaySearchSession.timeout,
         onFinish: @escaping (GlobalSearchResults) -> Void) {
        self.collector = LocalRelaySearchCollector(matcher: matcher)
        self.routes = routes
        self.timeout = timeout
        self.onFinish = onFinish
    }

    /// Folds in profiles the app already holds; see the collector's note on why
    /// the relay cannot answer a username search on its own.
    func addCachedProfiles(_ cached: [String: FeedProfile]) {
        collector.addCachedProfiles(cached)
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self, !self.didStart else { return }
            self.didStart = true

            guard !self.routes.isEmpty else {
                self.finish()
                return
            }

            for (index, url) in self.routes.enumerated() {
                let client = WebSocketClient()
                client.isTemporary = true
                self.clients.append(client)

                client.messageSubject
                    .receive(on: self.queue)
                    .sink { [weak self] message in self?.handle(message: message) }
                    .store(in: &self.cancellables)

                client.$connectionState
                    .receive(on: self.queue)
                    .sink { [weak self] state in
                        guard let self = self else { return }
                        switch state {
                        case .connected:
                            self.openStreams(routeIndex: index)
                        case .error:
                            // A route that cannot be reached must not hold the
                            // whole search open until the timeout.
                            self.failStreams(routeIndex: index)
                        case .disconnected:
                            // `connectionState` publishes `.disconnected` as its
                            // initial value, before `connect(url:)` is even
                            // called — only a drop AFTER the streams opened is
                            // a failure.
                            if self.activeByRoute[index] != nil {
                                self.failStreams(routeIndex: index)
                            }
                        case .connecting:
                            break
                        }
                    }
                    .store(in: &self.cancellables)

                client.connect(url: url)
            }
        }

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self = self else { return }
            if self.failureReason == nil { self.failureReason = "timed out" }
            self.finish()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.didFinish = true
            self.teardown()
        }
    }

    // MARK: Private

    /// Kinds are walked in this order, one after the other, not at the same
    /// time: a note matches if its author's profile matched, so the profiles
    /// have to be known before the notes are read. The extra round trip costs
    /// milliseconds against an on-box relay.
    private static let kindOrder = [0, 1]

    /// Opens the first paged subscription on a route that just connected.
    private func openStreams(routeIndex: Int) {
        guard !didFinish, !doneRoutes.contains(routeIndex) else { return }
        // Reconnects deliver `.connected` more than once; only open a route's
        // streams the first time.
        guard activeByRoute[routeIndex] == nil else { return }
        activeByRoute[routeIndex] = 1
        send(stream: Stream(routeIndex: routeIndex, kind: Self.kindOrder[0], page: 1), until: nil)
    }

    private func send(stream: Stream, until: Int64?) {
        guard routes.indices.contains(stream.routeIndex),
              clients.indices.contains(stream.routeIndex) else { return }
        let subId = "lsearch-\(UUID().uuidString.prefix(8))"
        var stream = stream
        stream.until = until
        streams[subId] = stream

        var filter: [String: Any] = [
            "kinds": [stream.kind],
            "limit": LocalRelaySearchPlan.pageLimit
        ]
        if let until = until { filter["until"] = until }

        let req = ["REQ", subId, filter] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            clients[stream.routeIndex].send(text: str)
        }
    }

    private func handle(message: String) {
        guard !didFinish else { return }
        switch collector.ingest(message: message) {
        case .ignored, .event:
            return
        case .eose(let subId):
            guard let stream = streams.removeValue(forKey: subId) else { return }
            close(subId: subId, routeIndex: stream.routeIndex)
            answeredRoutes.insert(stream.routeIndex)
            if let onProgress { onProgress(collector.snapshot()) }

            let stats = collector.takeStats(for: subId)
            switch LocalRelaySearchPlan.step(received: stats.received,
                                             newIds: stats.newIds,
                                             oldestCreatedAt: stats.oldestCreatedAt,
                                             pagesFetched: stream.page,
                                             until: stream.until) {
            case .done:
                // This kind is exhausted on this route: move on to the next
                // kind, and only when there is none is the route finished.
                if let index = Self.kindOrder.firstIndex(of: stream.kind),
                   index + 1 < Self.kindOrder.count {
                    send(stream: Stream(routeIndex: stream.routeIndex,
                                        kind: Self.kindOrder[index + 1],
                                        page: 1),
                         until: nil)
                } else {
                    activeByRoute[stream.routeIndex] = 0
                    markDone(routeIndex: stream.routeIndex)
                }
            case .next(let until):
                var next = stream
                next.page += 1
                send(stream: next, until: until)
            }
        }
    }

    private func close(subId: String, routeIndex: Int) {
        guard clients.indices.contains(routeIndex) else { return }
        let msg = ["CLOSE", subId] as [Any]
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let str = String(data: data, encoding: .utf8) {
            clients[routeIndex].send(text: str)
        }
    }

    /// A route's socket died: drop its in-flight streams so the remaining
    /// routes can still complete the search.
    private func failStreams(routeIndex: Int) {
        guard !didFinish, !doneRoutes.contains(routeIndex) else { return }
        if failureReason == nil { failureReason = "could not connect" }
        for (subId, stream) in streams where stream.routeIndex == routeIndex {
            streams.removeValue(forKey: subId)
        }
        activeByRoute[routeIndex] = 0
        markDone(routeIndex: routeIndex)
    }

    /// A route has nothing left in flight. The search ends only when EVERY
    /// route is done — a fast route draining first must not cut off a slower
    /// one that has not even opened its subscriptions yet.
    private func markDone(routeIndex: Int) {
        doneRoutes.insert(routeIndex)
        if doneRoutes.count >= routes.count { finish() }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        let results = collector.snapshot()
        teardown()
        let answered = !answeredRoutes.isEmpty
        onOutcome?(Outcome(answered: answered, reason: answered ? nil : (failureReason ?? "no response")))
        onFinish(results)
    }

    private func teardown() {
        for client in clients { client.disconnect() }
        clients.removeAll()
        cancellables.removeAll()
        streams.removeAll()
    }
}
