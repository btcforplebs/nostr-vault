import SwiftUI

/// Settings > Relays: every relay the owner uses on one screen (Logen
/// 2026-10-31, option A). "Yours" (the owner's published relay list and DM
/// inbox, plus relays added here) on top, "App defaults" (this device only)
/// below. Each row has the five job dots and Remove. Every edit is a draft
/// (`RelayDraft`): nothing is written or published until Save, and rows never
/// move while you tap. The owner's own relay is pinned on top. The
/// Recommended page has the fixes, relays the owner's follows write to and
/// the fastest relays from this device. Twin of Android `RelayMatrixScreen.kt`.
struct RelayMatrixView: View {
    @EnvironmentObject var configService: ConfigService
    @StateObject private var probe = RelayProbe()

    enum Page: String, CaseIterable, Identifiable {
        case relays = "Your Relays", recommended = "Recommended"
        var id: String { rawValue }
    }

    @State private var page: Page = .relays
    @State private var refusedCertificates: [String] = LocalTLSTrust.refusedHosts
    @State private var followSuggestions: [RelayMatrix.FollowSuggestion] = []
    @State private var followsWithLists = 0
    @State private var followCount = 0
    @State private var blockedPublishTask: Task<Void, Never>?

    @State private var searchRelays: [String] = SearchRelaySettings.relays
    @State private var selected: RelayDraft.Row?
    @State private var showingAdd = false
    @State private var newRelay = ""
    /// Nil until the published lists have been looked up.
    @State private var draft: RelayDraft.State?
    @State private var confirming = false
    @State private var confirmingDiscard = false
    @Environment(\.dismiss) private var dismiss

    private static let columnWidth: CGFloat = RelayDraftRowView.dotWidth

    // MARK: - Lists

    /// This device's saved lists.
    private var savedLists: RelayMatrix.Lists {
        RelayMatrix.Lists(
            read: configService.config.feedRelays,
            write: configService.config.blastrRelays,
            dms: configService.config.dmRelays,
            search: searchRelays,
            importing: configService.config.importSeedRelays)
    }

    /// The lists the screen shows: the draft once loaded, else the saved ones.
    private var lists: RelayMatrix.Lists { draft?.draft ?? savedLists }

    private var pinned: [String] { [ownRelay, configService.config.ownHavenDMInboxURL] }

    private var changes: Int { draft.map(RelayDraft.changeCount) ?? 0 }

    /// Changes the draft; nothing is written until `save`.
    private func edit(_ change: (RelayDraft.State) -> RelayDraft.State) {
        guard let state = draft else { return }
        let next = change(state)
        guard next != state else { return }
        draft = next
        // Only relays with no speed yet, so the timed rows keep their dots.
        probe.probe(RelayMatrix.needingProbe(next.layout.map(\.url), known: Set(probe.results.keys)))
    }

    private func loadDraft() {
        guard draft == nil else { return }
        Task {
            let published = await NostrService.shared.lookupOwnerRelayLists()
            guard draft == nil else { return }
            let state = RelayDraft.start(savedLists, published: published, pinned: pinned)
            draft = state
            probe.probe(RelayMatrix.needingProbe(state.layout.map(\.url), known: Set(probe.results.keys)))
            refreshSuggestions()
        }
    }

    private var plan: RelayDraft.Plan? {
        draft.map { RelayDraft.plan($0, ownRelays: configService.config.ownPublicRelays,
                                    ownInbox: configService.config.ownHavenDMInboxURL) }
    }

    /// The one place the relay lists are written and published.
    private func save() {
        guard let state = draft, let plan else { return }
        let new = state.draft
        configService.config.feedRelays = new.read
        configService.config.blastrRelays = new.write
        configService.config.dmRelays = new.dms
        configService.config.importSeedRelays = new.importing
        if new.search != SearchRelaySettings.relays {
            SearchRelaySettings.relays = new.search
        }
        searchRelays = SearchRelaySettings.relays
        configService.save()
        if let tags = plan.relayListTags { NostrService.shared.publishRelayListTags(tags) }
        if let dms = plan.dmRelays { NostrService.shared.publishOwnerDMRelays(dms) }
        draft = RelayDraft.saved(state, plan: plan)
    }

    private var blocked: [String] { configService.config.blockedRelays }

    /// Never connect: blocked now (kind 10006), out of the lists on Save.
    private func block(_ url: String) {
        setBlocked(RelayMatrix.blocking(url, lists: lists, blocked: blocked).1)
        edit { RelayDraft.remove($0, key: RelayMatrix.key(url)) }
    }

    private func unblock(_ url: String) {
        setBlocked(RelayMatrix.unblocking(url, blocked: blocked))
    }

    private func setBlocked(_ new: [String]) {
        guard new != blocked else { return }
        configService.config.blockedRelays = new
        refreshSuggestions()
        blockedPublishTask?.cancel()
        blockedPublishTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            blockedPublishTask = nil
            NostrService.shared.publishBlockedRelayList()
        }
    }

    /// The owner's own relay: the Mac relay on iPhone, this relay's public
    /// address on a Mac. Empty when there is none others can reach.
    private var ownRelay: String {
        configService.config.ownPublicRelays.first { !$0.isEmpty } ?? ""
    }

    private var rows: [RelayDraft.Row] { draft.map(RelayDraft.rows) ?? [] }

    private var problems: [RelayMatrix.Problem] {
        // Only the owner's relays: the probe also times suggestions.
        let yours = Set(([ownRelay] + rows.map(\.url)).filter { !$0.isEmpty }.map(RelayMatrix.key))
        return RelayMatrix.problems(lists, ownDMInbox: configService.config.ownHavenDMInboxURL,
                                    unreachable: probe.unreachable.filter(yours.contains))
    }

    // MARK: - Body

    var body: some View {
        List {
            summarySection
            switch page {
            case .relays:
                RelayDraftSections(
                    draft: draft, rows: rows, ownRow: ownRelay.isEmpty ? nil : AnyView(ownRow),
                    result: { probe.result(for: $0) },
                    open: { selected = $0 },
                    toggle: { key, job in edit { RelayDraft.toggle($0, key: key, job: job) } },
                    remove: { key in edit { RelayDraft.remove($0, key: key) } },
                    undo: { key in edit { RelayDraft.undo($0, key: key) } })
                if !blocked.isEmpty { neverConnectSection }
                mediaSection
            case .recommended:
                if !problems.isEmpty || !refusedCertificates.isEmpty { fixesSection }
                followsSection
                fastestSection
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .safeAreaInset(edge: .bottom) {
            if page == .relays, draft != nil { saveBar }
        }
        #if os(iOS)
        // Leaving with unsaved edits asks first: nothing was saved or published.
        .navigationBarBackButtonHidden(changes > 0)
        #endif
        .toolbar {
            #if os(iOS)
            if changes > 0 {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        confirmingDiscard = true
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                }
            }
            #endif
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
                    edit { RelayDraft.add($0, url: url, jobs: [.read, .write]) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It goes in Yours with Read and Write. Save publishes it.")
        }
        .sheet(item: $selected) { row in
            RelayDetailView(
                url: row.url,
                jobs: { currentJobs(for: row.url) },
                result: probe.result(for: row.url),
                set: { job, on in edit { RelayDraft.setJob($0, url: row.url, job: job, on: on) } },
                block: {
                    block(row.url)
                    selected = nil
                },
                remove: {
                    edit { RelayDraft.remove($0, key: row.id) }
                    selected = nil
                })
            .environmentObject(configService)
        }
        .sheet(isPresented: $confirming) {
            if let plan { RelaySaveSheet(plan: plan, changes: changes, save: save) }
        }
        .confirmationDialog("Discard \(RelaySaveSheet.changesLabel(changes))?", isPresented: $confirmingDiscard,
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Nothing has been saved or published.")
        }
        .onAppear {
            searchRelays = SearchRelaySettings.relays
            probe.probe(([ownRelay] + rows.map(\.url)).filter { !$0.isEmpty })
            loadDraft()
            refreshSuggestions()
        }
        .onReceive(NotificationCenter.default.publisher(for: LocalTLSTrust.certificateChanged)) { _ in
            refusedCertificates = LocalTLSTrust.refusedHosts
        }
        .onChange(of: page) { _, new in
            guard new == .recommended else { return }
            refreshSuggestions()
            probe.probe(RelayMatrix.wellKnownRelays.filter { !RelayBlocklist.isBlocked($0) }
                        + followSuggestions.map(\.url))
        }
        .onDisappear {
            // Leaving mid-debounce must not drop the blocked list publish.
            if blockedPublishTask != nil {
                blockedPublishTask?.cancel()
                NostrService.shared.publishBlockedRelayList()
            }
        }
    }

    private func currentJobs(for url: String) -> Set<RelayMatrix.Job> {
        rows.first { $0.id == RelayMatrix.key(url) }?.jobs ?? []
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            Picker("Page", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 8) {
                chip("\(rows.count + (ownRelay.isEmpty ? 0 : 1)) relays")
                if let average = averageMilliseconds { chip("avg \(average) ms") }
                if !problems.isEmpty || !refusedCertificates.isEmpty {
                    Button {
                        page = .recommended
                    } label: {
                        chip("⚠︎ \(problems.count + refusedCertificates.count) to fix", tint: .orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the fixes")
                }
                Spacer(minLength: 0)
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
    }

    private var averageMilliseconds: Int? {
        let yours = Set(([ownRelay] + rows.map(\.url)).filter { !$0.isEmpty }.map(RelayMatrix.key))
        let times = probe.results.filter { yours.contains($0.key) }.values.compactMap { result -> Int? in
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
            ForEach(refusedCertificates, id: \.self) { hostPort in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                        .foregroundColor(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(hostPort) changed its certificate").font(.appBody)
                        Text("The app won't connect until you trust the new one. Do that only if you reset or reinstalled that relay.")
                            .font(.appCaption).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Trust New") {
                        LocalTLSTrust.forget(hostPort)
                        refusedCertificates = LocalTLSTrust.refusedHosts
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.havenPurple)
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
            ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: problemIsBroken(problem) ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(problemIsBroken(problem) ? .red : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem.title).font(.appBody)
                        Text(problem.detail).font(.appCaption).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 8)
                    if case .unreachable(let key) = problem, let row = rows.first(where: { $0.id == key && !$0.removed }) {
                        Button("Remove") { edit { RelayDraft.remove($0, key: row.id) } }
                            .buttonStyle(.borderedProminent)
                            .tint(.havenPurple)
                            .controlSize(.small)
                    } else if problem == .noSearch {
                        Button("Defaults") {
                            edit { RelayDraft.resetSearch($0, defaults: SearchRelayDefaults.effective(stored: nil), pinned: pinned) }
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

    private var ownRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.circle.fill")
                .font(.title3)
                .foregroundColor(.havenPurple)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(RelayMatrix.label(ownRelay))
                    .font(.appBody)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    healthDot(probe.result(for: ownRelay))
                    subtitle(probe.result(for: ownRelay), tags: [])
                    RelayTag(text: "YOUR RELAY", tint: .havenPurple)
                    Spacer(minLength: 2)
                    HStack(spacing: 0) {
                        RelayJobDot(on: true, locked: true)
                        RelayJobDot(on: true, locked: true)
                        RelayJobDot(on: !configService.config.ownHavenDMInboxURL.isEmpty, locked: true)
                        ownSearchDot
                        RelayJobDot(on: false).opacity(0.3)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(RelayMatrix.label(ownRelay)), your relay. Always used for reading and writing.")
        }
        .padding(.vertical, 2)
    }

    private var ownSearchDot: some View {
        let on = lists.search.contains { RelayMatrix.key($0) == RelayMatrix.key(ownRelay) }
        return Button {
            edit { RelayDraft.setJob($0, url: ownRelay, job: .search, on: !on) }
        } label: {
            RelayJobDot(on: on)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search, \(RelayMatrix.label(ownRelay))")
        .accessibilityValue(on ? "On" : "Off")
    }

    private var saveBar: some View {
        VStack(spacing: 6) {
            Button {
                confirming = true
            } label: {
                Text(changes == 0 ? "Save" : "Save (\(RelaySaveSheet.changesLabel(changes)))")
                    .font(.appBody.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.havenPurple)
            .disabled(changes == 0)
            Text("Only Save publishes. App defaults, Search and Import stay on this device.")
                .font(.appCaption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
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

    // MARK: - Recommended

    /// Recomputed when the Recommended page opens or a list changes, not on
    /// every render: it walks every follow's relay list.
    private func refreshSuggestions() {
        let follows = FeedService.shared.followedPubkeys
        let outbox = NostrService.shared.outboxRelays
        followCount = follows.count
        followsWithLists = RelayMatrix.followsWithRelayLists(follows: follows, outbox: outbox)
        followSuggestions = RelayMatrix.followSuggestions(
            follows: follows, outbox: outbox, lists: lists, blocked: blocked,
            pinned: [ownRelay, configService.config.ownHavenDMInboxURL])
    }

    /// Follow suggestions still worth showing: not added since the page
    /// opened, and not down.
    private var visibleFollowSuggestions: [RelayMatrix.FollowSuggestion] {
        let taken = Set(rows.map(\.id) + blocked.map(RelayMatrix.key))
        return followSuggestions.filter {
            !taken.contains(RelayMatrix.key($0.url)) && probe.result(for: $0.url) != .unreachable
        }
    }

    private var followsSection: some View {
        Section {
            if visibleFollowSuggestions.isEmpty {
                Text(followsWithLists == 0
                     ? "None of your follows' relay lists have loaded yet. They load as you browse profiles and your feed."
                     : "You already read from the relays your follows use most.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
            ForEach(visibleFollowSuggestions, id: \.url) { suggestion in
                suggestionRow(suggestion.url,
                              detail: "\(suggestion.follows) follows write here",
                              addLabel: "Add") {
                    edit { RelayDraft.add($0, url: suggestion.url, jobs: [.read]) }
                }
            }
        } header: {
            Text("Your Follows Write To")
        } footer: {
            Text("Add puts it in Yours with Read; Save publishes it. Based on \(followsWithLists) of your \(followCount) follows' relay lists.")
        }
    }

    private var fastestRelays: [String] {
        var milliseconds: [String: Int] = [:]
        for (key, result) in probe.results {
            if case .answered(let ms) = result { milliseconds[key] = ms }
        }
        // A relay already suggested above isn't repeated here.
        return RelayMatrix.fastest(RelayMatrix.wellKnownRelays, milliseconds: milliseconds,
                                   lists: lists, blocked: blocked,
                                   pinned: [ownRelay, configService.config.ownHavenDMInboxURL]
                                       + visibleFollowSuggestions.map(\.url))
    }

    private var fastestSection: some View {
        Section {
            let fastest = fastestRelays
            if fastest.isEmpty {
                Text(RelayMatrix.wellKnownRelays.contains { probe.result(for: $0) == .probing }
                     ? "Measuring…" : "Nothing faster to suggest.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
            ForEach(fastest, id: \.self) { url in
                suggestionRow(url, detail: nil, addLabel: "Add") {
                    edit { RelayDraft.add($0, url: url, jobs: [.read, .write]) }
                }
            }
        } header: {
            Text("Fastest From This Device")
        } footer: {
            Text("Well-known public relays, timed from here just now. Add puts it in Yours with Read and Write; Save publishes it.")
        }
    }

    private func suggestionRow(_ url: String, detail: String?, addLabel: String,
                               add: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            healthDot(probe.result(for: url))
            VStack(alignment: .leading, spacing: 2) {
                Text(RelayMatrix.label(url))
                    .font(.appBody)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.middle)
                HStack(spacing: 0) {
                    subtitle(probe.result(for: url), tags: detail.map { [$0] } ?? [])
                }
            }
            Spacer(minLength: 8)
            Button(addLabel, action: add)
                .buttonStyle(.borderedProminent)
                .tint(.havenPurple)
                .controlSize(.small)
                .accessibilityLabel("Add \(RelayMatrix.label(url))")
        }
        .padding(.vertical, 2)
    }

    private var neverConnectSection: some View {
        Section {
            ForEach(blocked, id: \.self) { url in
                HStack {
                    Image(systemName: "nosign").foregroundColor(.red)
                    Text(RelayMatrix.label(url))
                        .font(.appBody)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Unblock") { unblock(url) }
                        .controlSize(.small)
                        .accessibilityLabel("Unblock \(RelayMatrix.label(url))")
                }
            }
        } header: {
            Text("Never Connect")
        } footer: {
            Text("The app won't open a connection to these, even when someone you follow uses them. Published as your blocked relay list (10006).")
        }
    }
}

/// A relay's detail: every job as a labelled switch (easier for VoiceOver
/// and small tap targets than the grid's dots), its speed, and what uses it.
private struct RelayDetailView: View {
    let url: String
    let jobs: () -> Set<RelayMatrix.Job>
    let result: RelayProbe.Result?
    let set: (RelayMatrix.Job, Bool) -> Void
    let block: () -> Void
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
                    if RelayMatrix.isPublicRelay(HavenConfig.normalizedRelayURL(url)) {
                        Button {
                            block()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Never Connect").font(.appBody).foregroundColor(.red)
                                Text("Remove it and block it everywhere in the app")
                                    .font(.appCaption).foregroundColor(.secondary)
                            }
                        }
                    }
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
