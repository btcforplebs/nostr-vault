import SwiftUI

// MARK: - Media servers

/// Your Blossom servers, whether each answers, and the files on this phone
/// that some server does not have yet, with the one action that copies them.
struct MediaServersPage: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @StateObject private var model = MediaServersModel()
    @State private var showFiles = false

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
                    if model.isCopying {
                        RowButton(title: "Stop") { model.stopCopy() }
                    } else {
                        RowButton(title: model.hasFailures ? "Retry" : "Copy") {
                            withAnimation(Motion.control) { showFiles = true }
                            model.startCopy()
                        }
                        .disabled(model.isScanning || (model.waiting ?? 0) == 0)
                    }
                }
            }
            if !model.files.isEmpty {
                DashboardDivider()
                Button {
                    withAnimation(Motion.control) { showFiles.toggle() }
                } label: {
                    ValueRow(icon: "list.bullet", title: showFiles ? "Hide files" : "Show files",
                             value: model.files.count.formatted(), chevron: !showFiles)
                }
                .buttonStyle(.plain)
                .accessibilityHint(showFiles ? "Hides the list of files" : "Lists each file and what happened to it")
                if showFiles {
                    ForEach(model.files) { file in
                        DashboardDivider()
                        MediaCopyFileRow(file: file, hostFor: model.host(for:))
                    }
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
        if let copy = model.copyCounts {
            let failed = model.files.filter(\.isFailed).count
            let tail = failed > 0 ? ", \(failed.formatted()) failed" : ""
            return "Sent \(copy.done.formatted()) of \(copy.total.formatted())\(tail). Now: \(model.copyingNow)."
        }
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
    /// Each file some server is missing, and what the last copy did with it.
    @Published private(set) var files: [MediaCopyFile] = []

    private var service: BlossomService?
    private var hashes: [String] = []
    private var fileURLs: [String: URL] = [:]
    private var copyTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var store: BlossomBackupStore { .shared }

    var isScanning: Bool { scanProgress != nil }
    var isCopying: Bool { copyCounts != nil }
    var hasFailures: Bool { files.contains(where: \.isFailed) }
    /// The files being sent right now, for the copy row's line.
    var copyingNow: String {
        let now = files.filter { $0.status == .copying }
        guard let first = now.first else { return "finishing" }
        return now.count == 1 ? first.title : "\(first.title) and \(now.count - 1) more"
    }

    func host(for server: String) -> String {
        servers.first(where: { $0.id == server })?.host ?? URL(string: server)?.host ?? server
    }
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
        let local = await Self.localFiles(configService: configService)
        guard generation == loadGeneration else { return }
        hashes = local.map(\.hash)
        fileURLs = Dictionary(local.map { ($0.hash, $0.url) }, uniquingKeysWith: { first, _ in first })
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
        rebuildFiles()
    }

    /// The list under the copy row: every file a server is missing. A file
    /// that failed keeps its reasons until it is tried again.
    private func rebuildFiles() {
        let previous = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        files = missing().sorted { $0.key < $1.key }.compactMap { hash, absentOn in
            guard let url = fileURLs[hash] else { return nil }
            var file = previous[hash] ?? MediaCopyFile(hash: hash, url: url)
            file.servers = absentOn
            if file.status == .copied || file.status == .copying { file.status = .waiting }
            return file
        }
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

    func startCopy() {
        guard !isCopying, service != nil else { return }
        copyTask = Task { await copyToServers() }
    }

    /// Stops after the files already on their way; the rest stay waiting.
    func stopCopy() {
        copyTask?.cancel()
    }

    /// Sends every file some server is missing, two at a time, and keeps
    /// what happened to each one on screen: waiting, sending, copied, or
    /// failed with the server's reason. The old loop sent one file at a time
    /// through a session that could wait 15 minutes for a connection, three
    /// times per file, and only moved its counter when a file was done.
    private func copyToServers() async {
        guard !isCopying, let service else { return }
        let work = files.indices.filter { files[$0].status != .copied }.map { files[$0].id }
        guard !work.isEmpty else { return }
        copyNote = nil
        for id in work { update(id) { $0.status = .waiting } }
        copyCounts = (0, work.count)
        service.appLog("copy to servers: \(work.count) file(s)")
        var done = 0
        let jobs = files.filter { work.contains($0.id) }.map { (id: $0.id, url: $0.url, servers: $0.servers) }
        var iterator = jobs.makeIterator()
        await withTaskGroup(of: (String, [String: BlobCopyOutcome]).self) { group in
            func addNext() -> String? {
                guard !Task.isCancelled, let job = iterator.next() else { return nil }
                group.addTask { (job.id, await service.copyStoredBlob(sha256: job.id, fileURL: job.url, to: job.servers)) }
                return job.id
            }
            for _ in 0..<2 {
                guard let id = addNext() else { break }
                update(id) { $0.status = .copying }
            }
            for await (id, outcomes) in group {
                record(id, outcomes)
                done += 1
                copyCounts = (done, work.count)
                if let next = addNext() { update(next) { $0.status = .copying } }
            }
        }
        let stopped = Task.isCancelled
        for id in work where files.first(where: { $0.id == id })?.status == .copying {
            update(id) { $0.status = .waiting }
        }
        copyCounts = nil
        copyTask = nil
        let failed = files.filter(\.isFailed).count
        let copied = work.count - files.filter { work.contains($0.id) && $0.status != .copied }.count
        // Only a copy that moved something counts as one.
        if copied > 0 { VaultHistory.lastServerCopy = Date() }
        files.removeAll { $0.status == .copied }
        waiting = missing().count
        service.appLog("copy to servers: \(copied) copied, \(failed) failed\(stopped ? ", stopped" : "")")
        if stopped {
            copyNote = "Stopped. \(copied.formatted()) copied; the rest are still waiting."
        } else if failed > 0 {
            copyNote = failed == 1
                ? "1 file couldn't be copied. The reason is under it in the list. Fix that, then tap Retry."
                : "\(failed.formatted()) files couldn't be copied. The reason is under each one. Fix that, then tap Retry."
        }
    }

    private func record(_ id: String, _ outcomes: [String: BlobCopyOutcome]) {
        let copiedTo = outcomes.compactMap { $0.value == .copied ? $0.key : nil }
        if !copiedTo.isEmpty {
            store.record(hash: id, presence: Dictionary(uniqueKeysWithValues: copiedTo.map { ($0, .present) }))
        }
        let failures = outcomes.compactMap { server, outcome -> MediaCopyFile.Failure? in
            guard case .failed(let reason) = outcome else { return nil }
            return .init(server: server, reason: reason)
        }.sorted { $0.server < $1.server }
        update(id) { file in
            file.servers.removeAll { copiedTo.contains($0) }
            file.status = failures.isEmpty ? .copied : .failed(failures)
        }
    }

    private func update(_ id: String, _ change: (inout MediaCopyFile) -> Void) {
        guard let i = files.firstIndex(where: { $0.id == id }) else { return }
        change(&files[i])
    }

    /// The blobs in this device's Blossom folder: files named by a hex SHA-256.
    private static func localFiles(configService: ConfigService) async -> [(hash: String, url: URL)] {
        let dir = configService.relayDataDir.appendingPathComponent(configService.config.blossomPath)
        return await Task.detached(priority: .userInitiated) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return files.compactMap { url in
                let hash = url.deletingPathExtension().lastPathComponent
                return (hash.count == 64 && hash.allSatisfy(\.isHexDigit)) ? (hash, url) : nil
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
