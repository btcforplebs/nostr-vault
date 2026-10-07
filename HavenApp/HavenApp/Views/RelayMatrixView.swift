import SwiftUI

/// Settings > Relays: every relay the owner uses on one screen. Each row is a
/// relay; the Read, Write and DMs columns are its jobs, tapped on and off.
/// Search and Import live in the relay's detail and show as a tag under its
/// name. The owner's own relay is pinned on top. See `RelayMatrix`.
struct RelayMatrixView: View {
    @EnvironmentObject var configService: ConfigService
    @StateObject private var probe = RelayProbe()

    @State private var searchRelays: [String] = SearchRelaySettings.relays
    @State private var selected: RelayMatrix.Row?
    @State private var showingAdd = false
    @State private var newRelay = ""
    @State private var dmPublishTask: Task<Void, Never>?
    @State private var relayListPublishTask: Task<Void, Never>?

    private static let columnWidth: CGFloat = 46

    // MARK: - Lists

    private var lists: RelayMatrix.Lists {
        RelayMatrix.Lists(
            read: configService.config.feedRelays,
            write: configService.config.blastrRelays,
            dms: configService.config.dmRelays,
            search: searchRelays,
            importing: configService.config.importSeedRelays)
    }

    private func apply(_ new: RelayMatrix.Lists) {
        let old = lists
        guard new != old else { return }
        if new.read != old.read { configService.config.feedRelays = new.read }
        if new.write != old.write { configService.config.blastrRelays = new.write }
        if new.importing != old.importing { configService.config.importSeedRelays = new.importing }
        if new.search != old.search {
            searchRelays = new.search
            SearchRelaySettings.relays = new.search
        }
        if new.dms != old.dms {
            configService.config.dmRelays = new.dms
            scheduleDMPublish()
        }
        if new.read != old.read || new.write != old.write { scheduleRelayListPublish() }
        probe.probe(rows.map(\.url))
    }

    /// The owner's own relay: the Mac relay on iPhone, this relay's public
    /// address on a Mac. Empty when there is none others can reach.
    private var ownRelay: String {
        configService.config.ownPublicRelays.first { !$0.isEmpty } ?? ""
    }

    private var rows: [RelayMatrix.Row] {
        RelayMatrix.rows(lists, pinned: [ownRelay, configService.config.ownHavenDMInboxURL])
    }

    private var problems: [RelayMatrix.Problem] {
        RelayMatrix.problems(lists, ownDMInbox: configService.config.ownHavenDMInboxURL,
                             unreachable: probe.unreachable)
    }

    // MARK: - Body

    var body: some View {
        List {
            summarySection
            if !problems.isEmpty { fixesSection }
            gridSection
            mediaSection
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    newRelay = ""
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add relay")
            }
        }
        .alert("Add Relay", isPresented: $showingAdd) {
            TextField("relay.example.com", text: $newRelay)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .autocorrectionDisabled(true)
            Button("Add") {
                if let url = RelayMatrix.relayURL(from: newRelay) {
                    apply(RelayMatrix.adding(url, to: lists))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It starts with Read and Write. Tap its name to change that.")
        }
        .sheet(item: $selected) { row in
            RelayDetailView(
                url: row.url,
                jobs: { currentJobs(for: row.url) },
                result: probe.result(for: row.url),
                set: { job, on in apply(RelayMatrix.setting(job, on, for: row.url, in: lists)) },
                remove: {
                    apply(RelayMatrix.removing(row.url, from: lists))
                    selected = nil
                })
            .environmentObject(configService)
        }
        .onAppear {
            searchRelays = SearchRelaySettings.relays
            probe.probe(([ownRelay] + rows.map(\.url)).filter { !$0.isEmpty })
        }
        .onDisappear {
            // Leaving mid-debounce must not drop the publish.
            if dmPublishTask != nil {
                dmPublishTask?.cancel()
                NostrService.shared.publishOwnerDMInboxList()
            }
            if relayListPublishTask != nil {
                relayListPublishTask?.cancel()
                publishRelayListIfEnabled()
            }
        }
    }

    private func currentJobs(for url: String) -> Set<RelayMatrix.Job> {
        rows.first { $0.id == RelayMatrix.key(url) }?.jobs ?? []
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            HStack(spacing: 8) {
                chip("\(rows.count + (ownRelay.isEmpty ? 0 : 1)) relays")
                if let average = averageMilliseconds { chip("avg \(average) ms") }
                if !problems.isEmpty {
                    chip("⚠︎ \(problems.count) to fix", tint: .orange)
                }
                Spacer(minLength: 0)
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
    }

    private var averageMilliseconds: Int? {
        let times = probe.results.values.compactMap { result -> Int? in
            if case .answered(let ms) = result { return ms }
            return nil
        }
        return times.isEmpty ? nil : times.reduce(0, +) / times.count
    }

    private func chip(_ text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.appCaption)
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private var fixesSection: some View {
        Section {
            ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: problemIsBroken(problem) ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(problemIsBroken(problem) ? .red : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.title).font(.appBody)
                        Text(problem.detail).font(.appCaption).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    if case .unreachable(let key) = problem, let row = rows.first(where: { $0.id == key }) {
                        Button("Remove") { apply(RelayMatrix.removing(row.url, from: lists)) }
                            .buttonStyle(.borderedProminent)
                            .tint(.havenPurple)
                            .controlSize(.small)
                    } else if problem == .noSearch {
                        Button("Defaults") {
                            SearchRelaySettings.resetToDefaults()
                            searchRelays = SearchRelaySettings.relays
                            probe.probe(searchRelays)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.havenPurple)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Fixes")
        }
    }

    private func problemIsBroken(_ problem: RelayMatrix.Problem) -> Bool {
        switch problem {
        case .oneDM: return false
        default: return true
        }
    }

    private var gridSection: some View {
        Section {
            if !ownRelay.isEmpty { ownRow }
            ForEach(rows) { row in
                relayRow(row)
            }
            if rows.isEmpty && ownRelay.isEmpty {
                Text("No relays yet. Tap + to add one.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
        } header: {
            HStack {
                Text("Relay")
                Spacer()
                ForEach(RelayMatrix.Job.columns) { job in
                    Text(job.title).frame(width: Self.columnWidth)
                }
            }
        } footer: {
            Text("Read + Write are your public relay list (10002). DMs are your DM inbox (10050). Tap a relay's name for Search and Import.")
        }
    }

    private var ownRow: some View {
        HStack(spacing: 10) {
            healthDot(probe.result(for: ownRelay))
            VStack(alignment: .leading, spacing: 2) {
                Text(RelayMatrix.label(ownRelay))
                    .font(.appBody)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    subtitle(probe.result(for: ownRelay), tags: [])
                    Text("YOUR RELAY")
                        .font(.appSystem(size: 9, weight: .bold))
                        .foregroundColor(.havenPurple)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.havenPurple.opacity(0.15)))
                }
            }
            Spacer(minLength: 4)
            lockedDot(true)
            lockedDot(true)
            lockedDot(!configService.config.ownHavenDMInboxURL.isEmpty)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(RelayMatrix.label(ownRelay)), your relay. Always used for reading and writing.")
    }

    private func relayRow(_ row: RelayMatrix.Row) -> some View {
        HStack(spacing: 10) {
            healthDot(probe.result(for: row.url))
            Button {
                selected = row
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(RelayMatrix.label(row.url))
                        .font(.appBody)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .truncationMode(.middle)
                    subtitle(probe.result(for: row.url),
                             tags: RelayMatrix.Job.advanced.filter(row.has).map(\.title))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows every job for this relay")
            ForEach(RelayMatrix.Job.columns) { job in
                jobDot(row, job)
            }
        }
    }

    private func jobDot(_ row: RelayMatrix.Row, _ job: RelayMatrix.Job) -> some View {
        let on = row.has(job)
        return Button {
            apply(RelayMatrix.setting(job, !on, for: row.url, in: lists))
        } label: {
            Circle()
                .fill(on ? Color.havenPurple : Color.clear)
                .overlay(Circle().stroke(on ? Color.havenPurple : Color.secondary.opacity(0.5), lineWidth: 1.5))
                .frame(width: 24, height: 24)
                .frame(width: Self.columnWidth, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(job.title), \(RelayMatrix.label(row.url))")
        .accessibilityValue(on ? "On" : "Off")
    }

    private func lockedDot(_ on: Bool) -> some View {
        ZStack {
            Circle()
                .fill(on ? Color.havenPurple : Color.clear)
                .overlay(Circle().stroke(on ? Color.havenPurple : Color.secondary.opacity(0.5), lineWidth: 1.5))
            if on {
                Image(systemName: "lock.fill")
                    .font(.appSystem(size: 9, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: 24, height: 24)
        .frame(width: Self.columnWidth, height: 40)
    }

    private func healthDot(_ result: RelayProbe.Result?) -> some View {
        Circle()
            .fill(RelayMatrixView.healthColor(result))
            .frame(width: 8, height: 8)
    }

    static func healthColor(_ result: RelayProbe.Result?) -> Color {
        switch result {
        case .answered(let ms): return ms > RelayProbe.slowMilliseconds ? .orange : .havenOnline
        case .unreachable: return .red
        case .probing, .none: return .secondary.opacity(0.4)
        }
    }

    private func subtitle(_ result: RelayProbe.Result?, tags: [String]) -> some View {
        var parts: [String] = []
        var tint = Color.secondary
        switch result {
        case .answered(let ms):
            parts.append("\(ms) ms")
            if ms > RelayProbe.slowMilliseconds {
                parts.append("slow")
                tint = .orange
            }
        case .unreachable:
            parts.append("not answering")
            tint = .red
        case .probing, .none:
            parts.append("…")
        }
        parts += tags
        return Text(parts.joined(separator: " · "))
            .font(.appCaption)
            .foregroundColor(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var mediaSection: some View {
        Section {
            let mirrors = configService.config.activeBlossomMirrors
            ForEach(mirrors, id: \.self) { mirror in
                Label(RelayMatrix.label(mirror.replacingOccurrences(of: "https://", with: "")), systemImage: "server.rack")
                    .font(.appBody)
                    .lineLimit(1)
            }
            NavigationLink {
                BlossomSettingsView()
                    .navigationTitle("Media Servers")
            } label: {
                Text(mirrors.isEmpty ? "Add a media server" : "Edit media servers")
                    .font(.appBody)
                    .foregroundColor(.havenPurple)
            }
        } header: {
            Text("Media Servers")
        } footer: {
            Text("Where your photos and videos are stored (Blossom). These aren't relays.")
        }
    }

    // MARK: - Publishing

    /// Edits are published once they settle, like the DM relay page did.
    private func scheduleDMPublish() {
        dmPublishTask?.cancel()
        dmPublishTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            dmPublishTask = nil
            NostrService.shared.publishOwnerDMInboxList()
        }
    }

    private func scheduleRelayListPublish() {
        relayListPublishTask?.cancel()
        relayListPublishTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            relayListPublishTask = nil
            publishRelayListIfEnabled()
        }
    }

    /// Read and Write are the public relay list, so a change republishes it
    /// for the owner when the owner has "Publish Relay List" on.
    private func publishRelayListIfEnabled() {
        let owner = configService.config.ownerNpub
        guard !owner.isEmpty, configService.config.publishRelayListPerAccount[owner] == true else { return }
        NostrService.shared.publishRelayList(forNpub: owner)
    }
}

/// A relay's detail: every job as a labelled switch (easier for VoiceOver
/// and small tap targets than the grid's dots), its speed, and what uses it.
private struct RelayDetailView: View {
    let url: String
    let jobs: () -> Set<RelayMatrix.Job>
    let result: RelayProbe.Result?
    let set: (RelayMatrix.Job, Bool) -> Void
    let remove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var current: Set<RelayMatrix.Job> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        Circle().fill(RelayMatrixView.healthColor(result)).frame(width: 10, height: 10)
                        Text(url).font(.appCaption).foregroundColor(.secondary).textSelection(.enabled)
                    }
                    if case .answered(let ms) = result {
                        LabeledContent("Speed from this device", value: "\(ms) ms")
                    } else if result == .unreachable {
                        LabeledContent("Speed from this device", value: "Not answering")
                    }
                }
                Section {
                    ForEach(RelayMatrix.Job.columns) { toggle($0) }
                }
                Section {
                    ForEach(RelayMatrix.Job.advanced) { toggle($0) }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Write without Read sends your posts here but never loads from it.")
                }
                Section {
                    LabeledContent("Used by", value: usedBy)
                }
                Section {
                    Button("Remove Relay", role: .destructive) { remove() }
                        .frame(maxWidth: .infinity)
                }
            }
            .groupedFormStyleCompat()
            .navigationTitle(RelayMatrix.label(url))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { current = jobs() }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func toggle(_ job: RelayMatrix.Job) -> some View {
        Toggle(isOn: Binding(
            get: { current.contains(job) },
            set: { on in
                set(job, on)
                current = jobs()
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.appBody)
                Text(job.detail).font(.appCaption).foregroundColor(.secondary)
            }
        }
        .tint(.havenPurple)
    }

    private var usedBy: String {
        var features: [String] = []
        if current.contains(.read) { features += ["Feed", "Profiles", "Threads", "Zaps", "Polls", "Live", "Reels"] }
        if current.contains(.write) { features += ["Your posts", "Reactions"] }
        if current.contains(.dms) { features.append("DMs") }
        if current.contains(.search) { features.append("Search") }
        if current.contains(.importing) { features.append("Import") }
        return features.isEmpty ? "Nothing" : features.joined(separator: ", ")
    }
}
