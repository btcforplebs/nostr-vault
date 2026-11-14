import Foundation
import WebKit

/// Serves `nvfips://<npub>/<path>` for the in-app browser: every request,
/// the page and its subresources, is read through the mesh door to that
/// npub's port 80 (`NvFipsIngress`, read-anyone through the seeds, mesh key
/// only), with `Host: <npub>.fips`, and streamed back as it arrives.
///
/// Nothing here touches DNS. Each page is capped in bytes, each request in
/// time. A mesh that is up but has no tree parent yet is waited for (with
/// "Waiting for the mesh…" in the bar) and then reported on the page as
/// "mesh not ready", instead of a run of silent resets.
@MainActor
final class FipsSchemeHandler: NSObject, WKURLSchemeHandler {
    /// One ask for the door to an npub. Live: FipsMeshService / MacFipsMeshService.
    typealias Ingress = @MainActor (String) async -> MeshSiteIngress

    /// All of one page's responses together, so a site can't fill memory.
    static let pageByteCap = 48 << 20
    /// A quiet site gives up like a slow server, but only after the mesh
    /// could have found it (MeshSiteRetry).
    static let requestTimeout = MeshSiteRetry.requestTimeout
    /// How long a page waits for the engine to find its tree parent.
    static let treeWait: TimeInterval = 45
    private static let treePoll: UInt64 = 3_000_000_000
    private static let maxRedirects = 5

    private let ingress: Ingress
    /// "Waiting for the mesh…" while a page waits for the tree; nil when done.
    var onStatus: ((String?) -> Void)?

    private var loads: [ObjectIdentifier: MeshLoad] = [:]
    private var bases: [String: URL] = [:]
    private var pageBytes = 0

    init(ingress: @escaping Ingress) {
        self.ingress = ingress
    }

    nonisolated static var live: Ingress {
        { npub in
            #if os(iOS)
            return await FipsMeshService.shared.siteIngress(meshNpub: npub)
            #else
            return await MacFipsMeshService.shared.siteIngress(meshNpub: npub)
            #endif
        }
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let load = MeshLoad(task: task)
        loads[ObjectIdentifier(task)] = load
        Task { await run(load) }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        loads.removeValue(forKey: ObjectIdentifier(task))?.stop()
    }

    // MARK: - One request

    private func run(_ load: MeshLoad) async {
        guard let url = load.task.request.url, let npub = FipsURL.npub(inViewer: url) else {
            return finish(load, page: .refused)
        }
        // Only a mesh page reads its own site: an internet page that embeds
        // `nvfips://` must not start the engine or dial npubs by itself.
        guard let main = load.task.request.mainDocumentURL, FipsURL.npub(inViewer: main) == npub else {
            return fail(load, URLError(.noPermissionsToReadFile))
        }
        let isMain = main == url
        if isMain { pageBytes = 0 }
        let method = load.task.request.httpMethod?.uppercased() ?? "GET"
        guard method == "GET" || method == "HEAD" else {
            // Reading only: a form post has nowhere honest to go.
            return finish(load, status: 405, html: Self.page(.readOnly, url: url))
        }

        // "Still reaching this site…" lasts until the page is answered.
        defer { if isMain { onStatus?(nil) } }
        var target = url
        var redirects = 0
        // A cold route resets the first asks: ask again until MeshSiteRetry.window.
        let firstAsk = Date()
        while redirects <= Self.maxRedirects {
            guard let base = await door(for: npub, load: load, isMain: isMain) else { return }
            guard load.isActive else { return }
            guard let request = Self.request(for: target, base: base, method: method) else {
                return finish(load, page: .refused)
            }
            let reply = await load.fetch(request, pageBudget: Self.pageByteCap - pageBytes) { [weak self] count in
                self?.pageBytes += count
            }
            guard load.isActive else { return }
            switch reply {
            case .done:
                return finish(load)
            case .redirect(let location):
                guard let next = FipsURL.redirectTarget(location, from: target) else {
                    return finish(load, page: .refused)
                }
                if isMain {
                    // The page itself moves: let WebKit navigate, so the
                    // address bar and history follow (and an off-mesh target
                    // goes through the navigation rules like any link).
                    return finish(load, status: 200, html: FipsURL.scheme == next.scheme?.lowercased()
                        ? Self.redirectPage(to: next) : Self.leavePage(to: next))
                }
                guard FipsURL.npub(inViewer: next) == npub else {
                    return fail(load, URLError(.redirectToNonExistentLocation))
                }
                target = next
                redirects += 1
            case .unreachable:
                // The door may be stale (the tree moved): ask afresh next time.
                bases[npub] = nil
                if MeshSiteRetry.shouldRetry(startedAt: firstAsk, now: Date()) {
                    if isMain { onStatus?("Still reaching this site…") }
                    try? await Task.sleep(nanoseconds: UInt64(MeshSiteRetry.pause * 1_000_000_000))
                    guard load.isActive else { return }
                    continue
                }
                return isMain ? finish(load, page: .unreachable) : fail(load, URLError(.cannotConnectToHost))
            case .tooBig:
                return isMain ? finish(load, page: .tooBig) : fail(load, URLError(.dataLengthExceedsMaximum))
            case .failedMidway(let error):
                return fail(load, error)
            }
        }
        fail(load, URLError(.httpTooManyRedirects))
    }

    /// The door to `npub`, waiting out a mesh that has no tree parent yet.
    /// Nil when the page was answered (an error page) or the load stopped.
    private func door(for npub: String, load: MeshLoad, isMain: Bool) async -> URL? {
        if let base = bases[npub] { return base }
        let deadline = Date().addingTimeInterval(Self.treeWait)
        var reply = await ingress(npub)
        var waited = false
        while reply.isWaiting, load.isActive, Date() < deadline {
            waited = true
            onStatus?("Waiting for the mesh…")
            try? await Task.sleep(nanoseconds: Self.treePoll)
            guard load.isActive else { break }
            reply = await ingress(npub)
        }
        // A page still being retried keeps its own line (run's defer clears it).
        if waited { onStatus?(nil) }
        guard load.isActive else { return nil }
        if let base = reply.url {
            bases[npub] = base
            return base
        }
        let page = MeshPage(reply)
        if isMain { finish(load, page: page) } else { fail(load, URLError(.notConnectedToInternet)) }
        return nil
    }

    nonisolated static func request(for viewer: URL, base: URL, method: String) -> URLRequest? {
        guard let door = FipsURL.ingressURL(base: base, forViewer: viewer),
              let host = FipsURL.hostHeader(forViewer: viewer) else { return nil }
        var request = URLRequest(url: door, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = method
        // The site's own name, as a browser on a FIPS daemon sends it; the
        // door passes Host through (fips-v2 stack.rs `check_head`).
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Answers

    private func finish(_ load: MeshLoad) {
        guard loads.removeValue(forKey: ObjectIdentifier(load.task)) != nil else { return }
        load.task.didFinish()
    }

    private func finish(_ load: MeshLoad, page: MeshPage) {
        finish(load, status: 200, html: Self.page(page, url: load.task.request.url))
    }

    private func finish(_ load: MeshLoad, status: Int, html: String) {
        guard loads.removeValue(forKey: ObjectIdentifier(load.task)) != nil,
              let url = load.task.request.url else { return }
        let body = Data(html.utf8)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": "\(body.count)",
            "Cache-Control": "no-store",
        ])!
        load.task.didReceive(response)
        load.task.didReceive(body)
        load.task.didFinish()
    }

    private func fail(_ load: MeshLoad, _ error: Error) {
        guard loads.removeValue(forKey: ObjectIdentifier(load.task)) != nil else { return }
        load.task.didFailWithError(error)
    }

    // MARK: - Pages the browser writes

    enum MeshPage: Equatable {
        case meshOff, engineOff, noSeeds, notReady, failed, unreachable, refused, tooBig, readOnly

        init(_ reply: MeshSiteIngress) {
            switch reply {
            case .meshOff: self = .meshOff
            case .engineOff: self = .engineOff
            case .noSeeds: self = .noSeeds
            case .notReady: self = .notReady
            case .failed, .ready: self = .failed
            }
        }

        var title: String {
            switch self {
            case .meshOff: return "The mesh is off"
            case .engineOff: return "The mesh isn't running"
            case .noSeeds: return "No middle server"
            case .notReady: return "Mesh not ready"
            case .failed: return "The mesh didn't open"
            case .unreachable: return "Can't reach this site"
            case .refused: return "This address can't open here"
            case .tooBig: return "This page is too big"
            case .readOnly: return "Reading only"
            }
        }

        var detail: String {
            switch self {
            case .meshOff:
                return "Turn it on in Settings → Mesh to open .fips sites."
            case .engineOff:
                return "The Mac's mesh runs once a device is listed under Settings → Mesh → My Devices."
            case .noSeeds:
                return "The middle server is set to None, so this device has no way to reach sites outside your own devices. Choose a middle server in Settings → Mesh → Advanced."
            case .notReady:
                return "The mesh is still finding its way onto the network. Try again in a moment."
            case .failed:
                return "Something stopped the mesh from opening a connection. Try again in a moment."
            case .unreachable:
                return "The site didn't answer over the mesh. It may be offline, or not on the same mesh as this device."
            case .refused:
                return "Only addresses in the form npub….fips open here, and only on port 80. They never go to the internet."
            case .tooBig:
                return "It went past what one page may load over the mesh."
            case .readOnly:
                return ".fips sites open for reading here; forms that send data can't be used."
            }
        }

        var retries: Bool { [.notReady, .failed, .unreachable].contains(self) }
    }

    nonisolated static func page(_ page: MeshPage, url: URL?) -> String {
        let shown = url.flatMap(FipsURL.siteURL(forViewer:))?.absoluteString ?? url?.absoluteString ?? ""
        let again = FipsURL.htmlEscaped(url?.absoluteString ?? "")
        let retry = page.retries ? #"<p><a class="b" href="\#(again)">Try again</a></p>"# : ""
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(FipsURL.htmlEscaped(page.title))</title>
        <style>
        :root{color-scheme:dark}
        body{font:17px -apple-system,system-ui,sans-serif;background:#111;color:#eee;margin:0;
        display:flex;min-height:100vh;align-items:center;justify-content:center;text-align:center}
        main{max-width:30em;padding:2em}
        h1{font-size:1.3em;margin:0 0 .6em}
        p{color:#aaa;line-height:1.45}
        code{color:#777;font-size:.8em;word-break:break-all}
        .b{display:inline-block;margin-top:.6em;padding:.55em 1.2em;border-radius:999px;background:#2a2a2e;color:#fff;text-decoration:none}
        </style></head><body><main>
        <h1>\(FipsURL.htmlEscaped(page.title))</h1>
        <p>\(FipsURL.htmlEscaped(page.detail))</p>
        \(retry)
        <p><code>\(FipsURL.htmlEscaped(shown))</code></p>
        </main></body></html>
        """
    }

    /// A mesh page that redirects to the internet: said, not followed. Its
    /// link is a tap like any other, so it asks before leaving the mesh.
    nonisolated static func leavePage(to url: URL) -> String {
        let target = FipsURL.htmlEscaped(url.absoluteString)
        let host = FipsURL.htmlEscaped(url.host ?? url.absoluteString)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Leaves the mesh</title>
        <style>
        :root{color-scheme:dark}
        body{font:17px -apple-system,system-ui,sans-serif;background:#111;color:#eee;margin:0;
        display:flex;min-height:100vh;align-items:center;justify-content:center;text-align:center}
        main{max-width:30em;padding:2em}
        h1{font-size:1.3em;margin:0 0 .6em}
        p{color:#aaa;line-height:1.45}
        code{color:#777;font-size:.8em;word-break:break-all}
        .b{display:inline-block;margin-top:.6em;padding:.55em 1.2em;border-radius:999px;background:#2a2a2e;color:#fff;text-decoration:none}
        </style></head><body><main>
        <h1>This page sends you to \(host)</h1>
        <p>That's on the internet, not the mesh: the site would see your IP address.</p>
        <p><a class="b" href="\(target)">Open on the web</a></p>
        <p><code>\(target)</code></p>
        </main></body></html>
        """
    }

    nonisolated static func redirectPage(to url: URL) -> String {
        let target = FipsURL.htmlEscaped(url.absoluteString)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="refresh" content="0;url=\(target)"></head>
        <body style="background:#111"></body></html>
        """
    }
}

/// One scheme task's fetch through the door, streamed into the task as it
/// arrives. Lives on the main thread with its handler: WebKit's task
/// methods may only be called there, and never after `stop`.
@MainActor
private final class MeshLoad: NSObject, URLSessionDataDelegate {
    enum Reply {
        case done
        case redirect(String)
        /// No byte came back: no route, a reset, a timeout.
        case unreachable
        case tooBig
        /// It had begun answering, then broke.
        case failedMidway(Error)
    }

    let task: WKURLSchemeTask
    private(set) var isActive = true
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var continuation: CheckedContinuation<Reply, Never>?
    private var started = false
    private var budget = 0
    private var onBytes: ((Int) -> Void)?

    init(task: WKURLSchemeTask) {
        self.task = task
    }

    func stop() {
        isActive = false
        dataTask?.cancel()
        resume(.done)
    }

    func fetch(_ request: URLRequest, pageBudget: Int, onBytes: @escaping (Int) -> Void) async -> Reply {
        guard isActive else { return .done }
        guard pageBudget > 0 else { return .tooBig }
        budget = pageBudget
        started = false
        self.onBytes = onBytes
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = FipsSchemeHandler.requestTimeout
        config.timeoutIntervalForResource = 120
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        // Loopback only: no proxy may see the door's token.
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        let dataTask = session.dataTask(with: request)
        self.dataTask = dataTask
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            dataTask.resume()
        }
    }

    private func resume(_ reply: Reply) {
        session?.invalidateAndCancel()
        session = nil
        dataTask = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: reply)
    }

    // MARK: URLSessionDataDelegate (on the main queue)

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The Location is the site's: resolved against the door it would
        // lose the token. The handler maps it instead.
        completionHandler(nil)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        MainActor.assumeIsolated {
            guard isActive, let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                return
            }
            if (300...399).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location") {
                completionHandler(.cancel)
                resume(.redirect(location))
                return
            }
            if http.expectedContentLength > Int64(budget) {
                completionHandler(.cancel)
                resume(.tooBig)
                return
            }
            started = true
            guard let url = task.request.url else { return completionHandler(.cancel) }
            task.didReceive(HTTPURLResponse(url: url, statusCode: http.statusCode, httpVersion: "HTTP/1.1",
                                            headerFields: Self.passedHeaders(http)) ?? http)
            completionHandler(.allow)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            guard isActive else { return }
            budget -= data.count
            onBytes?(data.count)
            guard budget >= 0 else {
                dataTask.cancel()
                resume(.failedMidway(URLError(.dataLengthExceedsMaximum)))
                return
            }
            task.didReceive(data)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task sessionTask: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let error else { return resume(.done) }
            if (error as? URLError)?.code == .cancelled { return resume(.done) }
            resume(started ? .failedMidway(error) : .unreachable)
        }
    }

    /// The site's headers, minus what no longer holds once URLSession has
    /// decoded the body (length, encoding) or what WebKit must not obey on a
    /// page it can't verify the origin of in TLS terms (HSTS, Alt-Svc).
    nonisolated static func passedHeaders(_ response: HTTPURLResponse) -> [String: String] {
        let dropped: Set<String> = ["content-length", "content-encoding", "transfer-encoding", "connection",
                                    "keep-alive", "strict-transport-security", "alt-svc", "set-cookie"]
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String,
                  !dropped.contains(key.lowercased()) else { continue }
            headers[key] = value
        }
        return headers
    }
}
