import SwiftUI
import UniformTypeIdentifiers

/// The Vault's Emoji page (RESEARCH/NV_CUSTOM_EMOJI_PLAN.md §4): the
/// account's emoji sets (its 10030), each emoji saved in the vault or not,
/// dead links on their own, Save copies, zip import, and add/remove a set.
/// On the iPhone it is a Vault page (VaultMode.emoji); on the Mac and iPad a
/// sidebar page. Android `ui/screens/emoji/EmojiVaultScreen.kt`.
struct EmojiVaultView: View {
    @ObservedObject private var library = EmojiListService.shared
    @ObservedObject private var store = EmojiVaultStore.shared
    @ObservedObject private var nostr = NostrService.shared
    @ObservedObject private var configService = ConfigService.shared
    @ObservedObject private var browser = EmojiSetBrowser.shared
    @Environment(\.inVaultTab) private var inVaultTab

    @State private var picked: EmojiVaultLogic.Row?
    @State private var pickedSet: String?
    @State private var addingSet = false
    @State private var importingZip = false
    @State private var removing: EmojiVaultLogic.SetPage?
    @State private var showUnmatched = false

    private var pages: [EmojiVaultLogic.SetPage] {
        EmojiVaultLogic.pages(sets: library.library.sets, copies: store.copies, dead: store.dead)
    }

    var body: some View {
        let pages = self.pages
        #if os(iOS)
        NavigationStack {
            content(pages)
                .navigationTitle(inVaultTab ? "" : "Emoji")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        #else
        content(pages)
            .navigationTitle("Emoji")
            .toolbar { toolbar }
        #endif
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(iOS)
        if inVaultTab {
            ToolbarItem(placement: .cancellationAction) {
                VaultModePill(mode: .emoji, zapsOnly: configService.config.zapsOnlyMode)
            }
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { addingSet = true } label: { Label("Add a set", systemImage: "plus") }
                Button { importingZip = true } label: { Label("Import a zip", systemImage: "doc.zipper") }
                    .disabled(store.isWorking || library.library.sets.isEmpty)
            } label: {
                Image(systemName: "plus.circle")
            }
            .accessibilityLabel("Add a set or import a zip")
        }
    }

    private func content(_ pages: [EmojiVaultLogic.SetPage]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: []) {
                GenmojiAddCard()
                if pages.isEmpty {
                    emptyState
                } else {
                    summaryCard(pages)
                    let dead = EmojiVaultLogic.deadLinks(pages)
                    if !dead.isEmpty { deadSection(dead) }
                    if !store.unmatchedZipFiles.isEmpty { unmatchedSection }
                    ForEach(pages) { page in setSection(page) }
                }
                findSetsSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable { library.refreshNow() }
        .onAppear {
            store.useActiveAccount()
            FileNotesLive.shared.start()
            library.refresh(maxAge: EmojiListService.pickerMaxAge)
        }
        .onDisappear { FileNotesLive.shared.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BlockedAccountsUpdated"))) { _ in browser.dropBlocked() }
        .onReceive(NotificationCenter.default.publisher(for: MuteListStore.settled)) { _ in browser.dropBlocked() }
        .task(id: browser.found.map(\.author)) {
            nostr.fetchMissingProfiles(for: Array(Set(browser.found.map(\.author))))
        }
        .task(id: pages.map(\.author)) {
            nostr.fetchMissingProfiles(for: Array(Set(pages.map(\.author).filter { !$0.isEmpty })))
        }
        .sheet(item: $picked) { row in
            EmojiDetailSheet(row: row, setTitle: pages.first { $0.address == pickedSet }?.title ?? "")
        }
        .sheet(isPresented: $addingSet) { AddEmojiSetSheet() }
        .fileImporter(isPresented: $importingZip, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.importZip(url, sets: library.library.sets)
            }
        }
        .confirmationDialog(removing.map { "Remove \($0.title)?" } ?? "", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let page = removing {
                Button("Remove from my emoji", role: .destructive) {
                    Task { _ = await store.setListed(page.address, on: false) }
                }
            }
        } message: {
            Text("Your emoji list is updated on your relays. Saved copies stay in your vault.")
        }
    }

    // MARK: Sections

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "face.smiling")
                .font(.appSystem(size: 44, weight: .thin))
                .foregroundColor(.secondary)
            Text("No emoji sets yet")
                .font(.appSystem(size: 18, weight: .bold))
            Text("Sets you add here, or in another Nostr app, show up on this page. Save copies keeps their images in your vault.")
                .font(.appSystem(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button { addingSet = true } label: { Label("Add a set", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .tint(Color.havenPurple)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func summaryCard(_ pages: [EmojiVaultLogic.SetPage]) -> some View {
        let total = Set(pages.flatMap(\.rows).map(\.emoji.url)).count
        let saved = Set(pages.flatMap(\.rows).filter { if case .saved = $0.status { return true }; return false }.map(\.emoji.url)).count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(saved) of \(total) saved")
                    .font(.appSystem(size: 20, weight: .bold))
                Spacer()
                Text("\(pages.count) \(pages.count == 1 ? "set" : "sets")")
                    .font(.appSystem(size: 14))
                    .foregroundColor(.secondary)
            }
            if let progress = store.progress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .tint(Color.havenPurple)
                    HStack {
                        Text("\(progress.title)… \(progress.done) of \(progress.total)")
                            .font(.appSystem(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Stop") { store.cancel() }
                            .font(.appSystem(size: 13, weight: .semibold))
                    }
                }
            } else {
                Button {
                    store.saveCopies(sets: library.library.sets)
                } label: {
                    Label(saved == total ? "All saved" : "Save copies", systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.havenPurple)
                .disabled(saved == total || store.isWorking)
            }
            if let result = store.lastResult {
                Text(result)
                    .font(.appSystem(size: 13, weight: .medium))
            }
            Text("Copies stay in your vault and reach your other devices. Nothing new is posted; your sets are kept in your vault too.")
                .font(.appSystem(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
    }

    private func deadSection(_ rows: [EmojiVaultLogic.Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title: "Dead links", detail: "\(rows.count)", tint: .red)
            Text("Not at their link or on any other server asked. A zip with these files (named by shortcode) fills them.")
                .font(.appSystem(size: 12))
                .foregroundColor(.secondary)
            grid(rows, set: nil)
            Button { importingZip = true } label: { Label("Import a zip", systemImage: "doc.zipper") }
                .font(.appSystem(size: 13, weight: .semibold))
                .disabled(store.isWorking)
        }
    }

    private var unmatchedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Motion.toggle) { showUnmatched.toggle() }
            } label: {
                HStack {
                    sectionHeader(title: "Skipped from the zip", detail: "\(store.unmatchedZipFiles.count)", tint: .secondary)
                    Image(systemName: showUnmatched ? "chevron.up" : "chevron.down")
                        .font(.appSystem(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            Text("These match no emoji in your sets. Making new sets comes later.")
                .font(.appSystem(size: 12))
                .foregroundColor(.secondary)
            if showUnmatched {
                ForEach(store.unmatchedZipFiles.prefix(200), id: \.self) { name in
                    Text(name).font(.appSystem(size: 12).monospaced()).foregroundColor(.secondary)
                }
            }
        }
    }

    private func setSection(_ page: EmojiVaultLogic.SetPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title)
                        .font(.appSystem(size: 17, weight: .bold))
                        .lineLimit(1)
                    Text(authorLine(page))
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Menu {
                    Button(role: .destructive) { removing = page } label: {
                        Label("Remove from my emoji", systemImage: "minus.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                }
                .disabled(store.listing.contains(page.address))
                .accessibilityLabel("\(page.title) options")
            }
            grid(page.rows, set: page.address)
        }
    }

    // MARK: Find emoji sets

    /// The account's 10030 sets, the fetched ones and any the list names.
    private var listedAddresses: Set<String> {
        var out = Set(library.library.sets.map(\.address))
        if let list = library.listEvent { out.formUnion(EmojiListParse.list(list.tags).setAddresses) }
        return out
    }

    /// Other people's sets, at the bottom of the page: people you follow
    /// first, then everyone's from the last month. Rows are the LazyVStack's
    /// own children, so a long answer draws as it scrolls.
    @ViewBuilder
    private var findSetsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Find emoji sets").font(.appSystem(size: 17, weight: .bold))
                Spacer()
                if browser.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { browser.browse(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Look again")
                }
            }
            Text("Sets by people you follow first, then everyone's from the last month. Add puts a set in your emoji list.")
                .font(.appSystem(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.top, 12)
        .onAppear { browser.browse() }
        if browser.asked && browser.found.isEmpty && !browser.loading {
            Text("No sets found on your relays.")
                .font(.appSystem(size: 14))
                .foregroundColor(.secondary)
        }
        let listed = listedAddresses
        let me = nostr.activeHexPubkey
        let old = library.answeredFor == me ? EmojiSetBrowse.oldSets(browser.ownVersions, owner: me, listed: listed) : []
        if !old.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your old sets").font(.appSystem(size: 15, weight: .bold))
                Text("Sets you made that are out of your emoji list or were emptied, from your vault and your relays.")
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)
            // Ids of their own: a set's address is also its page's id above,
            // and a LazyVStack draws one id once (seen in the sim: an old-set
            // row took a listed page's place).
            ForEach(old, id: \.rowID) { set in
                FoundSetRow(found: set.found,
                            detail: oldDetail(set),
                            title: "Add back",
                            listed: false,
                            busy: browser.restoring.contains(set.found.set.address) || store.listing.contains(set.found.set.address)) {
                    Task {
                        if let problem = await browser.addBack(set) {
                            ActionToastManager.shared.show(icon: "exclamationmark.triangle.fill", message: problem, tone: .error)
                        }
                    }
                }
            }
            Text("Everyone's sets").font(.appSystem(size: 15, weight: .bold)).padding(.top, 8)
        }
        let oldIDs = Set(old.map(\.id))
        ForEach(browser.found.filter { !oldIDs.contains($0.id) }, id: \.rowID) { found in
            let isListed = listed.contains(found.set.address)
            FoundSetRow(found: found,
                        detail: foundDetail(found),
                        title: isListed ? "Remove" : "Add",
                        listed: isListed,
                        busy: store.listing.contains(found.set.address)) {
                let address = found.set.address
                Task { _ = await store.setListed(address, on: !isListed) }
            }
        }
    }

    private func foundDetail(_ found: EmojiSetBrowse.Found) -> String {
        let name = nostr.profiles[found.author]?.bestName ?? String(found.author.prefix(8))
        var parts = ["by \(name)", "\(found.set.emojis.count) emoji"]
        if found.byFollow { parts.append("you follow") }
        return parts.joined(separator: " · ")
    }

    private func oldDetail(_ set: EmojiSetBrowse.OldSet) -> String {
        var parts = ["\(set.found.set.emojis.count) emoji",
                     Date(timeIntervalSince1970: TimeInterval(set.found.createdAt)).formatted(date: .abbreviated, time: .omitted)]
        if set.needsRestore { parts.append(set.listed ? "emptied, brings the emoji back" : "older version") }
        return parts.joined(separator: " · ")
    }

    private func authorLine(_ page: EmojiVaultLogic.SetPage) -> String {
        let name = nostr.profiles[page.author]?.bestName ?? String(page.author.prefix(8))
        var parts = ["by \(name)", "\(page.saved) of \(page.rows.count) saved"]
        if page.dead > 0 { parts.append("\(page.dead) dead") }
        return parts.joined(separator: " · ")
    }

    private func sectionHeader(title: String, detail: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.appSystem(size: 17, weight: .bold))
            Text(detail)
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(tint)
        }
    }

    private func grid(_ rows: [EmojiVaultLogic.Row], set: String?) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 52, maximum: 64), spacing: 8)], spacing: 8) {
            ForEach(rows) { row in
                Button {
                    pickedSet = set ?? row.emoji.setAddress
                    picked = row
                } label: {
                    EmojiTile(row: row)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One set in Find emoji sets: title, a detail line, a row of its emoji,
/// and one button (Add / Remove / Add back).
private struct FoundSetRow: View {
    let found: EmojiSetBrowse.Found
    let detail: String
    let title: String
    let listed: Bool
    let busy: Bool
    let action: () -> Void
    private static let preview = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(found.set.title)
                        .font(.appSystem(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: action) {
                    if busy {
                        ProgressView().controlSize(.small).frame(minWidth: 64)
                    } else {
                        Text(title).frame(minWidth: 64)
                    }
                }
                .buttonStyle(.bordered)
                .tint(listed ? .secondary : Color.havenPurple)
                .disabled(busy)
                .accessibilityLabel("\(title) \(found.set.title)")
            }
            HStack(spacing: 6) {
                ForEach(found.set.emojis.prefix(Self.preview), id: \.self) { e in
                    CustomEmojiImage(emoji: e, size: 28)
                }
                if found.set.emojis.count > Self.preview {
                    Text("+\(found.set.emojis.count - Self.preview)")
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

}

/// One emoji in the grid: its image (the saved copy first), with a corner
/// mark: a check when saved, a red dot when the link is dead.
private struct EmojiTile: View {
    let row: EmojiVaultLogic.Row

    private var savedHash: String? {
        if case .saved(let sha) = row.status { return sha }
        return nil
    }

    var body: some View {
        CustomEmojiImage(emoji: row.emoji, size: 36, savedHash: savedHash)
            .frame(width: 52, height: 52)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            .overlay(alignment: .topTrailing) {
                switch row.status {
                case .saved:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.appSystem(size: 12))
                        .foregroundStyle(.white, Color.green)
                        .padding(3)
                case .dead:
                    Circle().fill(Color.red).frame(width: 9, height: 9).padding(5)
                case .notSaved:
                    EmptyView()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.emoji.content)
            .accessibilityValue(Self.statusText(row.status))
    }

    static func statusText(_ status: EmojiVaultLogic.Status) -> String {
        switch status {
        case .saved: return "Saved in your vault"
        case .notSaved: return "Not saved yet"
        case .dead: return "Dead link, not saved"
        }
    }
}

/// One emoji, big: its shortcode, set, where it stands, and its link.
private struct EmojiDetailSheet: View {
    let row: EmojiVaultLogic.Row
    let setTitle: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                CustomEmojiImage(emoji: row.emoji, size: 128,
                                 savedHash: { if case .saved(let sha) = row.status { return sha }; return nil }())
                    .padding(.top, 24)
                Text(row.emoji.content)
                    .font(.appSystem(size: 20, weight: .bold).monospaced())
                    .textSelection(.enabled)
                if !setTitle.isEmpty {
                    Text("in \(setTitle)").font(.appSystem(size: 14)).foregroundColor(.secondary)
                }
                Label(EmojiTile.statusText(row.status), systemImage: icon)
                    .font(.appSystem(size: 14, weight: .medium))
                    .foregroundColor(row.status == .dead ? .red : .primary)
                Text(row.emoji.url)
                    .font(.appSystem(size: 12).monospaced())
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }

    private var icon: String {
        switch row.status {
        case .saved: return "checkmark.circle.fill"
        case .notSaved: return "icloud.and.arrow.down"
        case .dead: return "link.badge.plus"
        }
    }
}

/// Add a set by pasting its `naddr` or address: looked up, shown, then added
/// to the 10030 (EmojiVaultStore.setListed).
private struct AddEmojiSetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = EmojiListService.shared
    @State private var text = ""
    @State private var looking = false
    @State private var found: EmojiLibrary.EmojiSet?
    @State private var problem: String?
    @State private var adding = false

    private var address: String? { EmojiVaultLogic.setAddress(fromPaste: text) }
    private var alreadyAdded: Bool { library.library.sets.contains { $0.address == found?.address } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("naddr1… or 30030:…", text: $text, axis: .vertical)
                        .font(.appSystem(size: 14).monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onChange(of: text) { _, _ in found = nil; problem = nil }
                } footer: {
                    Text("Paste a link to an emoji set (kind 30030) from any Nostr app.")
                }
                if let problem {
                    Section { Text(problem).foregroundColor(.red) }
                }
                if let found {
                    Section(found.title) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 6)], spacing: 6) {
                            ForEach(found.emojis.prefix(48), id: \.self) { e in CustomEmojiImage(emoji: e, size: 32) }
                        }
                        Text("\(found.emojis.count) emoji").foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Add a set")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if found == nil {
                        Button(looking ? "Looking…" : "Look up") { lookUp() }
                            .disabled(address == nil || looking)
                    } else {
                        Button(alreadyAdded ? "Added" : adding ? "Adding…" : "Add") { add() }
                            .disabled(alreadyAdded || adding)
                    }
                }
            }
        }
    }

    private func lookUp() {
        guard let address else { return }
        looking = true
        Task {
            let result = await EmojiVaultStore.shared.lookUpSet(address)
            looking = false
            if let result { found = result.set } else { problem = "That set wasn't found on your relays or its author's." }
        }
    }

    private func add() {
        guard let found else { return }
        adding = true
        Task {
            let ok = await EmojiVaultStore.shared.setListed(found.address, on: true)
            adding = false
            if ok { dismiss() }
        }
    }
}
