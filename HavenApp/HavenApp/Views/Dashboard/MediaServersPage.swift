import SwiftUI

// MARK: - Media servers

/// Your Blossom servers, whether each answers, and the files on this phone
/// that some server does not have yet, with the one action that copies them.
struct MediaServersPage: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @StateObject private var model = MediaServersModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                serversSection
                mediaSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color.platformWindowBackground.ignoresSafeArea())
        .refreshable { await model.load(configService: configService, nostrService: nostrService) }
        .task { await model.load(configService: configService, nostrService: nostrService) }
    }

    // MARK: Servers

    private var serversSection: some View {
        DashboardSection(title: "Servers") {
            if model.servers.isEmpty {
                Text("None set up. Add one in Vault settings › Media Servers.")
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(model.servers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 { DashboardDivider() }
                    ServerRow(server: server) { Task { await model.test(server.id) } }
                }
            }
        }
    }

    // MARK: Your media

    private var mediaSection: some View {
        DashboardSection(title: "Your media") {
            ValueRow(icon: VaultMode.media.symbol, title: "Files stored",
                     value: model.filesStored.map { $0.formatted() } ?? "—")
            DashboardDivider()
            ValueRow(icon: "clock.arrow.circlepath", title: "Waiting to copy", value: waitingText)
            // Always there once a server is set up, so the card keeps its
            // height while the check runs instead of growing a row a minute in.
            if !model.servers.isEmpty {
                DashboardDivider()
                DashboardRow(
                    icon: "arrow.up.circle.fill",
                    title: "Copy to servers",
                    detail: copyDetail,
                    state: .info,
                    progress: model.copyProgress
                ) {
                    RowButton(title: "Copy", isLoading: model.isCopying) {
                        Task { await model.copyToServers() }
                    }
                    .disabled(model.isCopying || model.isScanning || (model.waiting ?? 0) == 0)
                }
            }
            if let note = model.copyNote {
                DashboardDivider()
                Text(note)
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }

    private var waitingText: String {
        if model.servers.isEmpty { return "—" }
        if let scan = model.scanProgress { return "Checking \(scan.done.formatted()) of \(scan.total.formatted())" }
        return model.waiting.map { $0.formatted() } ?? "—"
    }

    private var copyDetail: String {
        if let copy = model.copyCounts { return "Copied \(copy.done.formatted()) of \(copy.total.formatted())." }
        if model.isScanning || model.waiting == nil { return "Checking which files your servers are missing…" }
        let last = VaultHistory.lastServerCopy.map { " Last copied \($0.formatted(.relative(presentation: .named)))." } ?? ""
        switch model.waiting ?? 0 {
        case 0: return "Every file is on your servers." + last
        case 1: return "1 file is only on this phone." + last
        case let n: return "\(n.formatted()) files are only on this phone." + last
        }
    }
}

/// One Blossom server: status dot, host, when it was last checked, and Test.
private struct ServerRow: View {
    let server: MediaServersModel.Server
    let onTest: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.host)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(statusLine(now: context.date))
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            // The spinner takes the button's place, so the row does not move.
            ZStack {
                RowButton(title: "Test", action: onTest)
                    .opacity(server.status == .checking ? 0 : 1)
                    .disabled(server.status == .checking)
                if server.status == .checking {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var dotColor: Color {
        switch server.status {
        case .working: return .havenOnline
        case .answers, .lostFile: return .orange
        case .offline: return .red
        case .checking, .unknown: return .secondary.opacity(0.4)
        }
    }

    private func statusLine(now: Date) -> String {
        let state: String
        switch server.status {
        case .checking: return "Checking…"
        case .unknown: return "Not checked yet"
        case .working: state = "Has your files"
        case .answers: state = "Answers, but holds none of your files to check"
        case .lostFile: state = "Answers, but a file it had is gone"
        case .offline: state = "Not answering"
        }
        guard let at = server.checkedAt else { return state }
        let ago = now.timeIntervalSince(at) < 60 ? "just now" : at.formatted(.relative(presentation: .named))
        return "\(state) · checked \(ago)"
    }
}

// MARK: - Media servers model

/// The Media servers page's state: each server's health, the files on this
/// phone, and which of them some server is missing. "Waiting to copy" is
/// measured, never assumed: the old Blossom panel showed every file as
/// needing backup until a backup ran. Answers go into `BlossomBackupStore`
/// and are reused from it, so the grid's x/y badges agree with this page and
/// a file is asked about once per session, not on every open.
@MainActor
final class MediaServersModel: ObservableObject {
    struct Server: Identifiable, Equatable {
        enum Status: Equatable {
            case unknown, checking
            /// Holds a file of yours it was asked for: a real Blossom server.
            case working
            /// Answered, but there was no file of yours to ask it for. A web
            /// server that is not Blossom answers too, so this is not green.
            case answers
            /// Had one of your files and now says it does not.
            case lostFile
            case offline
        }
        let id: String
        let host: String
        var status: Status = .unknown
        var checkedAt: Date?
    }

    @Published private(set) var servers: [Server] = []
    @Published private(set) var filesStored: Int?
    /// Files on this phone that at least one server says it does not have.
    /// Nil until checked. A server that does not answer is not counted as
    /// missing a file: copying to it would fail anyway.
    @Published private(set) var waiting: Int?
    @Published private(set) var scanProgress: (done: Int, total: Int)?
    @Published private(set) var copyCounts: (done: Int, total: Int)?
    @Published private(set) var copyNote: String?

    private var service: BlossomService?
    private var hashes: [String] = []
    private var loadGeneration = 0
    private var store: BlossomBackupStore { .shared }

    var isScanning: Bool { scanProgress != nil }
    var isCopying: Bool { copyCounts != nil }
    var copyProgress: Double? {
        guard let c = copyCounts, c.total > 0 else { return nil }
        return Double(c.done) / Double(c.total)
    }

    func load(configService: ConfigService, nostrService: NostrService) async {
        guard !isCopying else { return }
        loadGeneration += 1
        let generation = loadGeneration
        service = BlossomService(configService: configService, nostrService: nostrService)
        let urls = configService.config.activeBlossomMirrors
        let previous = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        servers = urls.map { url in
            previous[url] ?? Server(id: url, host: URL(string: url)?.host ?? url)
        }
        hashes = await Self.localHashes(configService: configService)
        guard generation == loadGeneration else { return }
        filesStored = hashes.count
        guard !urls.isEmpty else { return }

        async let tests: Void = testAll()
        async let scanned: Void = scan(generation: generation)
        _ = await (tests, scanned)
        // The check may have found a file a server holds; a server that only
        // "answered" can now be tested against it.
        guard generation == loadGeneration else { return }
        await withTaskGroup(of: Void.self) { group in
            for server in servers where server.status == .answers {
                group.addTask { await self.test(server.id) }
            }
        }
    }

    private func testAll() async {
        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                group.addTask { await self.test(server.id) }
            }
        }
    }

    /// Asks the server for a file of yours it is known to hold. A 401 or 404
    /// from its front page proves nothing; holding your file does. With no
    /// such file, it can only be shown as answering.
    func test(_ id: String) async {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].status = .checking
        let status: Server.Status
        if let service, let proof = hashes.first(where: { store.presence(hash: $0)?[id] == .present }) {
            let answer = await service.checkPresence(mirror: id, sha256: proof)
            store.record(hash: proof, presence: [id: answer])
            switch answer {
            case .present: status = .working
            case .absent: status = .lostFile
            case .unreachable: status = .offline
            }
        } else if let url = URL(string: id) {
            status = await Self.answers(url) ? .answers : .offline
        } else {
            status = .offline
        }
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].status = status
        servers[i].checkedAt = Date()
    }

    /// Which files a server is missing. Answers the store already has for
    /// every current server are used as they are; only the rest are asked,
    /// four at a time, and recorded. A server that could not be asked last
    /// time is asked again: it may be back.
    private func scan(generation: Int) async {
        guard let service else { return }
        let mirrors = servers.map(\.id)
        let unknown = hashes.filter { hash in
            guard let known = store.presence(hash: hash) else { return true }
            return !mirrors.allSatisfy { known[$0] != nil && known[$0] != .unreachable }
        }
        let total = hashes.count
        var done = total - unknown.count
        scanProgress = (done, total)
        var iterator = unknown.makeIterator()
        await withTaskGroup(of: (String, [String: BlobPresence]).self) { group in
            func addNext() -> Bool {
                guard let hash = iterator.next() else { return false }
                group.addTask { (hash, await service.checkMirrorPresence(sha256: hash)) }
                return true
            }
            for _ in 0..<4 { if !addNext() { break } }
            for await (hash, presence) in group {
                if Task.isCancelled || generation != loadGeneration { group.cancelAll(); break }
                store.record(hash: hash, presence: presence)
                done += 1
                scanProgress = (done, total)
                _ = addNext()
            }
        }
        guard generation == loadGeneration else { return }
        scanProgress = nil
        // Stopped early (the page closed): nothing measured, nothing claimed.
        guard done == total else { return }
        waiting = missing().count
    }

    /// Hash → the servers that said they do not have it.
    private func missing() -> [String: [String]] {
        let mirrors = servers.map(\.id)
        var result: [String: [String]] = [:]
        for hash in hashes {
            guard let known = store.presence(hash: hash) else { continue }
            let absentOn = mirrors.filter { known[$0] == .absent }
            if !absentOn.isEmpty { result[hash] = absentOn }
        }
        return result
    }

    func copyToServers() async {
        guard !isCopying, let service else { return }
        let work = missing().sorted { $0.key < $1.key }
        guard !work.isEmpty else { return }
        copyNote = nil
        copyCounts = (0, work.count)
        var failed = 0
        for (index, item) in work.enumerated() {
            if await service.pushLocalToMirrors(sha256: item.key, only: item.value) {
                store.record(hash: item.key, presence: Dictionary(uniqueKeysWithValues: item.value.map { ($0, .present) }))
            } else {
                failed += 1
            }
            copyCounts = (index + 1, work.count)
        }
        copyCounts = nil
        // Only a copy that moved something counts as one.
        if failed < work.count { VaultHistory.lastServerCopy = Date() }
        waiting = missing().count
        copyNote = failed == 0 ? nil
            : "\(failed.formatted()) couldn't be copied. Test the servers above, then try again."
    }

    /// The blobs in this device's Blossom folder: files named by a hex SHA-256.
    private static func localHashes(configService: ConfigService) async -> [String] {
        let dir = configService.relayDataDir.appendingPathComponent(configService.config.blossomPath)
        return await Task.detached(priority: .userInitiated) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return files.compactMap { url in
                let hash = url.deletingPathExtension().lastPathComponent
                return (hash.count == 64 && hash.allSatisfy(\.isHexDigit)) ? hash : nil
            }
        }.value
    }

    /// The fallback when there is no file to ask for: does anything answer
    /// at the server's address at all (below 500).
    private static func answers(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<500).contains(http.statusCode)
    }
}
