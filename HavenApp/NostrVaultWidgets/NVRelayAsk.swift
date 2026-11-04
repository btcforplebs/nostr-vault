import Foundation

// MARK: - One-shot relay ask
//
// The widget's only relay client: open a socket per relay, send one REQ, keep
// every EVENT until EOSE, close. Time-boxed hard, because a timeline provider
// that runs long gets its entry dropped -- a slow relay must cost us its
// answers, never the whole widget.
enum NVRelayAsk {
    struct Result {
        var events: [[String: Any]]
        /// Relays that sent EOSE: zero means "could not check", not "nobody".
        var answered: Int
    }

    static func ask(_ relays: [URL], filters: [[String: Any]], timeout: TimeInterval) async -> Result {
        guard !relays.isEmpty, !filters.isEmpty else { return Result(events: [], answered: 0) }
        let subId = "nvw-\(UUID().uuidString.prefix(8))"
        let message: [Any] = ["REQ", subId] + filters
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let req = String(data: data, encoding: .utf8) else { return Result(events: [], answered: 0) }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        return await withTaskGroup(of: (events: [[String: Any]], answered: Bool).self) { group in
            for url in relays {
                group.addTask { await askOne(url, req: req, subId: subId, session: session, timeout: timeout) }
            }
            var out = Result(events: [], answered: 0)
            for await part in group {
                out.events += part.events
                if part.answered { out.answered += 1 }
            }
            return out
        }
    }

    private static func askOne(_ url: URL, req: String, subId: String, session: URLSession,
                               timeout: TimeInterval) async -> (events: [[String: Any]], answered: Bool) {
        let task = session.webSocketTask(with: url)
        task.resume()
        // The deadline closes the socket, which is what ends a `receive()`
        // that would otherwise wait on a silent relay forever.
        let guardTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer {
            guardTask.cancel()
            task.cancel(with: .goingAway, reason: nil)
        }

        do { try await task.send(.string(req)) } catch { return ([], false) }

        var events: [[String: Any]] = []
        while true {
            guard let message = try? await task.receive() else { break }
            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
                  let type = json.first as? String else { continue }
            if type == "EOSE" { return (events, true) }
            if type == "CLOSED" { return (events, false) }
            if type == "EVENT", json.count >= 3, json[1] as? String == subId,
               let event = json[2] as? [String: Any] {
                events.append(event)
            }
        }
        return (events, false)
    }
}
