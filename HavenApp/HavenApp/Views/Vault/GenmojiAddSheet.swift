import SwiftUI

/// Make or paste one Genmoji, name it, pick the set, Save. Repeats, one at a
/// time, until Done. Saving is public, and the button says so
/// (GenmojiSets.saveLabel / publicNote; the flow is GenmojiSaver).
@available(iOS 18.0, macOS 15.0, *)
struct GenmojiAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = EmojiListService.shared
    @ObservedObject private var nostr = NostrService.shared
    @StateObject private var saver = GenmojiSaver()

    @State private var pick: GenmojiPick?
    @State private var png: Data?
    @State private var shortcode = ""
    @State private var setChoice = GenmojiSets.defaultD
    @State private var newSetTitle = ""
    /// Shortcodes saved this session, until the library catches up.
    @State private var savedHere: Set<String> = []
    /// Sets made this session, until the library catches up.
    @State private var madeHere: [GenmojiSets.Target] = []
    @State private var unreadable = false

    private static let newSet = "\u{0}new"

    private var targets: [GenmojiSets.Target] {
        let known = GenmojiSets.targets(sets: library.library.sets, me: nostr.activeHexPubkey)
        return known + madeHere.filter { m in !known.contains { $0.d == m.d } }
    }
    private var taken: Set<String> { GenmojiSets.takenShortcodes(library.library).union(savedHere) }
    private var isNewSet: Bool { setChoice == Self.newSet }
    private var trimmedNewTitle: String { newSetTitle.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var chosen: (d: String, title: String)? {
        if isNewSet {
            guard !trimmedNewTitle.isEmpty else { return nil }
            return (GenmojiSets.newSetD(title: trimmedNewTitle, taken: Set(targets.map(\.d))), trimmedNewTitle)
        }
        let t = targets.first { $0.d == setChoice } ?? targets[0]
        return (t.d, t.title)
    }
    private var problem: String? { pick == nil ? nil : GenmojiSets.problem(shortcode: shortcode, taken: taken) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let png, let image = PlatformImage(data: png) {
                        HStack(spacing: 16) {
                            Image(platformImage: image)
                                .resizable().interpolation(.high).scaledToFit()
                                .frame(width: 72, height: 72)
                                .accessibilityLabel(pick?.description ?? "Genmoji")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pick?.description ?? "")
                                    .font(.appSystem(size: 14)).foregroundColor(.secondary)
                                Button("Use a different one") { clearPick() }
                                    .font(.appSystem(size: 13))
                                    .disabled(saver.isWorking)
                            }
                        }
                    } else {
                        GenmojiField { accept($0) }
                            .frame(minHeight: 52)
                    }
                } header: {
                    Text("Genmoji")
                } footer: {
                    if unreadable {
                        Text("That Genmoji's picture couldn't be read. Try another.").foregroundColor(.red)
                    } else if png == nil {
                        #if os(iOS)
                        Text("Tap the Genmoji button in the emoji keyboard to make one, or paste one from Messages.")
                        #else
                        Text("Make one in the emoji viewer (Edit → Emoji & Symbols), or paste one from Messages.")
                        #endif
                    }
                }

                if pick != nil {
                    Section {
                        HStack(spacing: 0) {
                            Text(":").foregroundColor(.secondary)
                            TextField("name", text: $shortcode)
                                .font(.appSystem(size: 16).monospaced())
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                            Text(":").foregroundColor(.secondary)
                        }
                        if let problem { Text(problem).font(.appSystem(size: 13)).foregroundColor(.red) }
                    } header: { Text("Shortcode") }

                    Section {
                        Picker("Set", selection: $setChoice) {
                            ForEach(targets, id: \.d) { Text($0.title).tag($0.d) }
                            Text("New set…").tag(Self.newSet)
                        }
                        if isNewSet {
                            TextField("Set name", text: $newSetTitle)
                        }
                    } header: { Text("Add to") }
                }

                Section {
                    switch saver.state {
                    case .working(let text):
                        HStack { ProgressView(); Text(text).foregroundColor(.secondary) }
                    case .saved(let text):
                        Label(text, systemImage: "checkmark.circle.fill").foregroundColor(.green)
                    case .failed(let text):
                        Label(text, systemImage: "exclamationmark.triangle.fill").foregroundColor(.red)
                    case .idle:
                        EmptyView()
                    }
                    if pick != nil, let chosen {
                        Button(GenmojiSets.saveLabel(setTitle: chosen.title)) { save() }
                            .disabled(problem != nil || png == nil || saver.isWorking)
                    }
                } footer: {
                    Text(GenmojiSets.publicNote)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Genmoji")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(saver.isWorking)
                }
            }
            .onAppear { EmojiVaultStore.shared.useActiveAccount() }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 460)
        #endif
        .interactiveDismissDisabled(saver.isWorking)
    }

    private func accept(_ new: GenmojiPick) {
        guard !saver.isWorking else { return }
        saver.reset()
        guard let data = GenmojiImage.largestFramePNG(new.imageContent) else {
            unreadable = true
            return
        }
        unreadable = false
        pick = new
        png = data
        shortcode = GenmojiSets.shortcode(for: new.description, taken: taken)
    }

    private func clearPick() {
        pick = nil
        png = nil
        shortcode = ""
        saver.reset()
    }

    private func save() {
        guard let png, let chosen, problem == nil else { return }
        let code = shortcode
        Task {
            await saver.save(png: png, shortcode: code, d: chosen.d, title: chosen.title)
            if case .saved = saver.state {
                savedHere.insert(code)
                if isNewSet {
                    madeHere.append(GenmojiSets.Target(d: chosen.d, title: chosen.title, exists: true))
                    setChoice = chosen.d
                    newSetTitle = ""
                }
                pick = nil
                self.png = nil
                shortcode = ""
            }
        }
    }
}
