import SwiftUI

/// Merge old versions of one list into the list now (Logen 2026-11-02:
/// small, one line per version and one Merge + save; single entries are
/// managed later in the normal list screens). Per-entry ticks only behind
/// Review. Only the list now is decrypted on open; an older version's
/// private part when it is ticked; newer locked ones on the Merge tap. Twin
/// of web `RecoverListPage.jsx` and Android `ListMergeScreen.kt`.
struct ListMergeView: View {
    let key: ListHistory.Key
    @ObservedObject private var service = ListBackupService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var current: ListVersionMerge.Opened?
    @State private var versions: [ListVersionMerge.Opened] = []
    /// The ids of the versions the vault keeps, newest first (a current found
    /// only on relays isn't one): a step outside its newest 20 can't be told.
    @State private var vaultIDs: [String] = []
    @State private var picked: Set<String> = []
    @State private var rows: [ListVersionMerge.Row]?
    @State private var loading = true
    @State private var working = false
    @State private var shrinkOK = false
    @State private var problem: String?
    @State private var done: String?

    private var kind: Int { key.kind }
    private var name: String { ListShrinkRule.name(kind) }
    private var others: [ListVersionMerge.Opened] { versions.filter { $0.id != current?.id } }
    private var chosen: [ListVersionMerge.Opened] { others.filter { picked.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if loading {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking your newest \(name)…").foregroundColor(.secondary) }
                    } else if let current {
                        Text("Your \(name) now: \(entries(current.entries.count)), from \(ListBackupFormat.date(current.version.createdAt)).")
                    } else {
                        Text("No current \(name) list of yours was found.")
                    }
                    if let current, !current.reason.isEmpty {
                        Label("Its private part couldn't be opened, so it can't be merged.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                    if let done {
                        Label(done, systemImage: "checkmark.circle.fill").foregroundColor(.havenOnline)
                    } else if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    }
                }
                if !loading && done == nil {
                    Section {
                        ForEach(others) { o in versionRow(o) }
                    } footer: {
                        Text("Tick the versions to bring back. Everything in your list now stays. You can change single entries later in the list itself.")
                    }
                    if let rows { confirm(rows) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Merge \(name)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(done == nil ? "Cancel" : "Done") { dismiss() } }
                if done == nil && rows == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Merge + save") { Task { await merge() } }
                            .disabled(loading || working || chosen.count < (current == nil ? 2 : 1) || !(current?.reason.isEmpty ?? true))
                    }
                }
            }
        }
        .task { await load() }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }

    private func entries(_ n: Int) -> String { n == 1 ? "1 entry" : "\(n) entries" }

    private func versionRow(_ o: ListVersionMerge.Opened) -> some View {
        let issue = ListVersionMerge.pickProblem(o)
        let d = ListVersionMerge.delta(o, current: current)
        let line = issue ?? ListVersionMerge.deltaLine(kind: kind, added: d.added, removed: d.removed)
            + (o.locked ? " · private part opens when you tick it" : "")
        return Toggle(isOn: Binding(get: { picked.contains(o.id) }, set: { on in Task { await tick(o, on) } })) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(ListVersionWording.app(o.version)), \(ListBackupFormat.date(o.version.createdAt))")
                Text(line).font(.appCaption).foregroundColor(.secondary)
            }
        }
        .disabled(issue != nil || working)
    }

    @ViewBuilder
    private func confirm(_ rows: [ListVersionMerge.Row]) -> some View {
        let sum = ListVersionMerge.summary(kind: kind, rows: rows)
        let nothing = sum.added == 0 && sum.removed == 0
        Section {
            Text(nothing ? "Nothing to bring back."
                 : kind == 3 ? ListVersionWording.followMergeLine(added: sum.added, removed: sum.removed) + " Signed by you; the list you have now stays in your vault's history."
                 : "Saves your \(name) as \(entries(sum.total)): \(sum.added) back\(sum.removed > 0 ? ", \(sum.removed) taken out" : ""). Signed by you; the list you have now stays in your vault's history.")
            let back = rows.filter { $0.ticked && $0.status != .current }
            if !back.isEmpty {
                Text("\(ListVersionWording.titles(kind).back) (\(back.count))").font(.appCaption).foregroundColor(.secondary)
                // A short list shows every row: they're few, and all came back ticked.
                let shown = back.count < ListVersionMerge.shortList ? back.count : 5
                ForEach(back.prefix(shown)) { r in ListEntryLabel(key: r.key) }
                if back.count > shown { Text("and \(back.count - shown) more, all in Review").font(.appCaption).foregroundColor(.secondary) }
            }
            if sum.leftOut > 0 {
                Text("\(sum.leftOut) you removed yourself later \(sum.leftOut == 1 ? "stays" : "stay") out.").foregroundColor(.secondary)
            }
            if sum.unsure > 0 {
                Text("\(sum.unsure) we can't tell about \(sum.unsure == 1 ? "stays" : "stay") out; tick \(sum.unsure == 1 ? "it" : "them") in Review.").foregroundColor(.secondary)
            }
            if !sum.remutes.isEmpty {
                Text("This mutes again: \(sum.remutes.line).").foregroundColor(.orange)
            }
            if sum.removed > 0 {
                Toggle("Yes, take \(entries(sum.removed)) out of the list I have now.", isOn: $shrinkOK)
            }
            Button(working ? "Saving…" : "Save") { Task { await save(rows) } }
                .disabled(working || nothing || sum.total == 0 || (sum.removed > 0 && !shrinkOK))
            Button("Cancel", role: .cancel) { self.rows = nil }
                .disabled(working)
            if sum.showsReview {
                NavigationLink("Review") {
                    ListMergeReview(kind: kind, rows: Binding(get: { self.rows ?? [] }, set: { self.rows = $0; shrinkOK = false }))
                }
                .font(.appCaption)
            }
        }
    }

    private func decrypt(_ me: String) -> (String) async throws -> String {
        { try await MuteListStore.decryptToSelf($0, me: me, nip04: ListVersionMerge.isNip04($0)) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let kept = service.groups[key] ?? []
        guard let newest = kept.first else { return }
        switch await NostrService.shared.currentList(like: newest, vaultNewest: service.vaultEvents(for: newest).first) {
        case .failure(let error): problem = error.message
        case .success(let event):
            var all = kept
            // Only the vault's own run has no holes; an imported one may (web unbroken()).
            vaultIDs = kept.filter { !service.importedIDs.contains($0.id) }.sorted(by: ListHistory.newerFirst).map(\.id)
            if let event, !all.contains(where: { $0.id == event.id }) { all.insert(ListVersion(event), at: 0) }
            var opened: [ListVersionMerge.Opened] = []
            for v in all { opened.append(await ListVersionMerge.open(v, decrypt: v.id == event?.id ? decrypt(v.pubkey) : nil)) }
            versions = opened.sorted(by: ListVersionMerge.newerFirst)
            current = event.flatMap { e in versions.first { $0.id == e.id } }
        }
    }

    private func tick(_ o: ListVersionMerge.Opened, _ on: Bool) async {
        rows = nil
        guard on else { picked.remove(o.id); return }
        if o.locked {
            let opened = await ListVersionMerge.open(o.version, decrypt: decrypt(o.version.pubkey))
            if let i = versions.firstIndex(where: { $0.id == o.id }) { versions[i] = opened }
            guard opened.reason.isEmpty else { return }
        }
        picked.insert(o.id)
    }

    private func merge() async {
        working = true
        defer { working = false }
        let me = current?.version.pubkey ?? chosen.first?.version.pubkey ?? ""
        versions = await ListVersionMerge.openForMerge(versions, picked: chosen, decrypt: decrypt(me))
        shrinkOK = false
        rows = ListVersionMerge.build(current: current, picked: chosen, all: versions, vault: vaultIDs)
        ListEntryLabel.loadPeople((rows ?? []).filter { $0.status != .current }.map(\.key))
    }

    private func save(_ rows: [ListVersionMerge.Row]) async {
        working = true
        defer { working = false }
        let (tags, privateTags) = ListVersionMerge.tags(rows, current: current)
        let vault = current.map { service.vaultEvents(for: $0.version) } ?? []
        let authors = Set(([current].compactMap { $0 } + chosen).map(\.version.pubkey))
        if let error = await NostrService.shared.saveMergedList(kind: kind, base: current, authors: authors, tags: tags, privateTags: privateTags, vaultVersions: vault) {
            problem = error.message
            if error.message.contains("changed while") { self.rows = nil; await service.load(); await load() }
        } else {
            let total = ListVersionMerge.summary(kind: kind, rows: rows).total
            done = "Saved: your \(name) now has \(entries(total)). The list you had stays in your vault's history."
            self.rows = nil
            await service.load()
        }
    }
}

/// Review: the merged entries, each with a tick.
private struct ListMergeReview: View {
    let kind: Int
    @Binding var rows: [ListVersionMerge.Row]

    var body: some View {
        let titles = ListVersionWording.titles(kind)
        Form {
            section(titles.back, rows.indices.filter { rows[$0].status != .current },
                    footer: ListVersionMerge.relayKinds.contains(kind)
                        ? "Everything an older relay list held comes back ticked; untick what you don't want back."
                        : "In a list of \(ListVersionMerge.shortList) or more, ones you removed yourself, and ones we can't tell about, are left unticked; tick them to bring them back.")
            section(titles.stays, rows.indices.filter { rows[$0].status == .current },
                    footer: kind == 3 ? "Untick someone to unfollow them." : "Untick an entry to take it out.")
        }
        .formStyle(.grouped)
        .navigationTitle("Review")
        .onAppear { ListEntryLabel.loadPeople(rows.map(\.key)) }
    }

    @ViewBuilder
    private func section(_ title: String, _ indices: [Int], footer: String) -> some View {
        if !indices.isEmpty {
            Section {
                ForEach(indices.prefix(500), id: \.self) { i in
                    Toggle(isOn: $rows[i].ticked) { ListEntryLabel(key: rows[i].key, note: note(rows[i])) }
                }
                if indices.count > 500 { Text("and \(indices.count - 500) more").foregroundColor(.secondary) }
            } header: {
                Text("\(title) (\(indices.count))")
            } footer: {
                Text(footer)
            }
        }
    }

    private func note(_ r: ListVersionMerge.Row) -> String? {
        let when = ListBackupFormat.date(r.at)
        var parts: [String] = []
        if r.status == .lost { parts.append("Lost \(when)") }
        if r.status == .removed { parts.append("You removed this \(when)") }
        if r.status == .unsure { parts.append("Can't tell if you removed this") }
        if r.isPrivate { parts.append("Private") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
