import SwiftUI

// The Vault Dashboard's two detail pages, under Advanced. Pushed inside the
// dashboard sheet and built from its own sections and rows, so they read as
// part of it: no status header, no relay controls, no console. Those live
// once, on the dashboard itself. These replaced the old relay and Blossom
// dashboards, which carried their own copies of all three.

// MARK: - Relay details

/// Where the vault is and what it holds, by kind.
struct RelayDetailsPage: View {
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var statsService: StatsService

    @State private var counts: [Int: Int] = [:]
    @State private var isCounting = false
    @State private var didCopyAddress = false
    @State private var showingBreakdown = false

    private var config: HavenConfig { configService.config }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                relaySection
                storedSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color.platformWindowBackground.ignoresSafeArea())
        .refreshable { await count() }
        .task(id: relayManager.isRunning) { await count() }
        .sheet(isPresented: $showingBreakdown) {
            EventKindBreakdownView()
                .environmentObject(statsService)
        }
    }

    // MARK: Your relay

    private var relaySection: some View {
        DashboardSection(title: "Your relay") {
            Button(action: copyAddress) {
                HStack(spacing: 8) {
                    RowLabel(icon: "link", title: "Address")
                    Spacer(minLength: 8)
                    Text(didCopyAddress ? "Copied" : config.nostrURL)
                        .font(.appSystem(size: 13, design: didCopyAddress ? .default : .monospaced))
                        .foregroundColor(didCopyAddress ? .havenOnline : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: didCopyAddress ? "checkmark" : "doc.on.doc")
                        .font(.appSystem(size: 11, weight: .semibold))
                        .foregroundColor(didCopyAddress ? .havenOnline : .secondary.opacity(0.6))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Address"))
            .accessibilityValue(Text(didCopyAddress ? "Copied" : config.nostrURL))
            .accessibilityHint(Text("Copies the address"))
            DashboardDivider()
            ValueRow(icon: "number", title: "Port", value: "\(config.relayPort)")
            DashboardDivider()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ValueRow(icon: "clock", title: "Running for", value: uptime(now: context.date))
            }
        }
    }

    private func uptime(now: Date) -> String {
        guard relayManager.isRunning, let start = relayManager.startDate else {
            return relayManager.isBooting ? "Starting…" : "Not running"
        }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3_600, minutes = (seconds % 3_600) / 60
        return days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private func copyAddress() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config.nostrURL, forType: .string)
        #else
        UIPasteboard.general.string = config.nostrURL
        #endif
        withAnimation(Motion.control) { didCopyAddress = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(Motion.control) { didCopyAddress = false }
        }
    }

    // MARK: What's stored

    /// Kinds grouped the way people think of them. Anything not named here
    /// (and every kind the count does not ask about) is "Other".
    private static let groups: [(title: String, icon: String, kinds: [Int])] = [
        ("Notes", VaultMode.notes.symbol, [1]),
        ("Articles", VaultMode.articles.symbol, [30023, 30024]),
        ("Reactions", VaultMode.likes.symbol, [7]),
        ("Reposts", "arrow.2.squarepath", [6, 16]),
        ("Zaps", VaultMode.zaps.symbol, [9734, 9735]),
        ("Messages", "envelope.fill", [4, 1059]),
        ("Profile and lists", "person.crop.circle",
         [0, 3, 10000, 10001, 10002, 10003, 10005, 10006, 10015, 10030, 30000, 30001, 30002]),
    ]

    /// The count's total, under key -1 (see `StatsService.fetchCountsByKind`).
    private var total: Int? { counts[-1] }

    private var groupRows: [(title: String, icon: String, count: Int)] {
        var rows: [(title: String, icon: String, count: Int)] = Self.groups.map { group in
            (group.title, group.icon, group.kinds.reduce(0) { $0 + (counts[$1] ?? 0) })
        }
        let named = rows.reduce(0) { $0 + $1.count }
        if let total, total > named {
            rows.append(("Other", "ellipsis.circle", total - named))
        }
        return rows.filter { $0.count > 0 }
    }

    private var storedSection: some View {
        DashboardSection(title: "What's stored", detail: total.map { $0.formatted() }) {
            if counts.isEmpty {
                HStack(spacing: 8) {
                    if isCounting { ProgressView().controlSize(.small) }
                    Text(isCounting ? "Counting…"
                         : relayManager.isRunning ? "Couldn't count. Pull down to try again."
                         : "Start your vault to count what's in it.")
                        .font(.appSystem(size: 13))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            } else {
                let rows = groupRows
                ForEach(Array(rows.enumerated()), id: \.element.title) { index, row in
                    if index > 0 { DashboardDivider() }
                    Button { showingBreakdown = true } label: {
                        ValueRow(icon: row.icon, title: row.title, value: row.count.formatted(), chevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Shows every kind"))
                }
            }
        }
    }

    private func count() async {
        guard relayManager.isRunning else { return }
        isCounting = true
        let fresh = await statsService.fetchCountsByKind()
        // An incomplete answer comes back empty; keep what is shown.
        if !fresh.isEmpty { counts = fresh }
        isCounting = false
    }
}

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
            if model.isCopying || (model.waiting ?? 0) > 0 {
                DashboardDivider()
                DashboardRow(
                    icon: "arrow.up.circle.fill",
                    title: "Copy to servers",
                    detail: copyDetail,
                    state: .info,
                    progress: model.copyProgress
                ) {
                    RowButton(title: "Copy", isLoading: model.isCopying) {
                        Task { await model.copyToServers(configService: configService, nostrService: nostrService) }
                    }
                    .disabled(model.isCopying || model.isScanning)
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
        let n = model.waiting ?? 0
        return n == 1 ? "1 file is only on this phone." : "\(n.formatted()) files are only on this phone."
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
        case .online: return .havenOnline
        case .offline: return .red
        case .checking, .unknown: return .secondary.opacity(0.4)
        }
    }

    private func statusLine(now: Date) -> String {
        switch server.status {
        case .checking: return "Checking…"
        case .unknown: return "Not checked yet"
        case .online, .offline:
            let state = server.status == .online
                ? (server.responseTime.map { "Answering, \($0) ms" } ?? "Answering")
                : "Not answering"
            guard let at = server.checkedAt else { return state }
            let ago = now.timeIntervalSince(at) < 60 ? "just now" : at.formatted(.relative(presentation: .named))
            return "\(state) · checked \(ago)"
        }
    }
}

/// A label and a value on one line, the shape of the dashboard's setting rows.
private struct ValueRow: View {
    let icon: String
    let title: String
    let value: String
    var chevron = false

    var body: some View {
        HStack(spacing: 8) {
            RowLabel(icon: icon, title: title)
            Spacer(minLength: 8)
            Text(value)
                .font(.appSystem(size: 15))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Media servers model

/// The Media servers page's state: each server's health, the files on this
/// phone, and which of them some server is missing. "Waiting to copy" is
/// measured (a HEAD per file per server) each time the page opens, never
/// assumed: the old Blossom panel showed every file as needing backup until a
/// backup ran.
@MainActor
final class MediaServersModel: ObservableObject {
    struct Server: Identifiable, Equatable {
        enum Status: Equatable { case unknown, checking, online, offline }
        let id: String
        let host: String
        var status: Status = .unknown
        var responseTime: Int?
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

    /// Hash → the servers missing it.
    private var missing: [String: [String]] = [:]
    private var loadGeneration = 0

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
        let urls = configService.config.activeBlossomMirrors
        let previous = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        servers = urls.map { url in
            previous[url] ?? Server(id: url, host: URL(string: url)?.host ?? url)
        }
        let hashes = await Self.localHashes(configService: configService)
        guard generation == loadGeneration else { return }
        filesStored = hashes.count

        await withTaskGroup(of: Void.self) { group in
            for server in servers {
                group.addTask { await self.test(server.id) }
            }
        }
        guard generation == loadGeneration, !urls.isEmpty else { return }
        await scan(hashes: hashes, configService: configService, nostrService: nostrService, generation: generation)
    }

    func test(_ id: String) async {
        guard let index = servers.firstIndex(where: { $0.id == id }), let url = URL(string: id) else { return }
        servers[index].status = .checking
        let result = await Self.ping(url)
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].status = result.ok ? .online : .offline
        servers[i].responseTime = result.ms
        servers[i].checkedAt = Date()
    }

    private func scan(hashes: [String], configService: ConfigService, nostrService: NostrService, generation: Int) async {
        let service = BlossomService(configService: configService, nostrService: nostrService)
        scanProgress = (0, hashes.count)
        var found: [String: [String]] = [:]
        var done = 0
        // A few at a time: each check is a HEAD to every server.
        var iterator = hashes.makeIterator()
        await withTaskGroup(of: (String, [String]).self) { group in
            func addNext() -> Bool {
                guard let hash = iterator.next() else { return false }
                group.addTask {
                    let presence = await service.checkMirrorPresence(sha256: hash)
                    return (hash, presence.filter { $0.value == .absent }.map(\.key))
                }
                return true
            }
            for _ in 0..<4 { if !addNext() { break } }
            for await (hash, absentOn) in group {
                if Task.isCancelled || generation != loadGeneration { group.cancelAll(); break }
                if !absentOn.isEmpty { found[hash] = absentOn }
                done += 1
                scanProgress = (done, hashes.count)
                _ = addNext()
            }
        }
        guard generation == loadGeneration else { return }
        scanProgress = nil
        // Stopped early (the page closed): nothing measured, nothing claimed.
        guard done == hashes.count else { return }
        missing = found
        waiting = found.count
    }

    func copyToServers(configService: ConfigService, nostrService: NostrService) async {
        guard !isCopying, !missing.isEmpty else { return }
        let service = BlossomService(configService: configService, nostrService: nostrService)
        let work = missing.sorted { $0.key < $1.key }
        copyNote = nil
        copyCounts = (0, work.count)
        var failed: [String: [String]] = [:]
        for (index, item) in work.enumerated() {
            let ok = await service.pushLocalToMirrors(sha256: item.key, only: item.value)
            if !ok { failed[item.key] = item.value }
            copyCounts = (index + 1, work.count)
        }
        copyCounts = nil
        missing = failed
        waiting = failed.count
        copyNote = failed.isEmpty
            ? "Every file is on your servers."
            : "\(failed.count.formatted()) couldn't be copied. Test the servers above, then try again."
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

    /// Any HTTP answer below 500 means the server is up (many answer 404 or
    /// 401 at their root).
    private static func ping(_ url: URL) async -> (ok: Bool, ms: Int?) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) {
                return (true, ms)
            }
            return (false, ms)
        } catch {
            return (false, nil)
        }
    }
}
