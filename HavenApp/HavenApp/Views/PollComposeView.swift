import SwiftUI

/// Posts a NIP-88 poll (kind 1068): a question, two to ten options, single or
/// multiple choice, and when voting closes. It goes out the way a vote does:
/// stored on this device's relay, blasted on, and sent straight to the
/// outside relays it names for its votes.
struct PollComposeView: View {
    var onDismiss: () -> Void
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    @State private var draft = PollDraft()
    @State private var closes: Closing = .oneDay
    @State private var customEnd = Date().addingTimeInterval(24 * 3600)
    @State private var isPosting = false
    @State private var error: String?
    @FocusState private var focusedOption: Int?

    /// When voting closes, from the moment Post is tapped.
    enum Closing: String, CaseIterable, Identifiable {
        case oneHour = "1 hour"
        case oneDay = "1 day"
        case threeDays = "3 days"
        case oneWeek = "1 week"
        case never = "Never"
        case custom = "Pick a time"

        var id: String { rawValue }

        var interval: TimeInterval? {
            switch self {
            case .oneHour: return 3600
            case .oneDay: return 24 * 3600
            case .threeDays: return 3 * 24 * 3600
            case .oneWeek: return 7 * 24 * 3600
            case .never, .custom: return nil
            }
        }
    }

    private func endDate(now: Date = Date()) -> Date? {
        switch closes {
        case .never: return nil
        case .custom: return customEnd
        default: return closes.interval.map { now.addingTimeInterval($0) }
        }
    }

    private var readyDraft: PollDraft {
        var d = draft
        d.endsAt = endDate()
        return d
    }

    /// Why Post is off, when the reason is not plain from the form.
    private var hint: String? {
        let labels = draft.filledOptions
        if Set(labels.map { $0.lowercased() }).count != labels.count { return "Two options are the same." }
        if closes == .custom, customEnd <= Date() { return "Pick a closing time that's still ahead." }
        return nil
    }

    /// The relays the poll names for its votes: your outside (blastr) relays,
    /// where it is sent, so voters and counters look where it lives.
    private var pollRelays: [String] {
        let blastr = configService.config.activeBlastrRelays.filter { $0.hasPrefix("wss://") }
        return blastr.isEmpty ? ["wss://relay.primal.net", "wss://nos.lol"] : blastr
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Ask a question", text: $draft.question, axis: .vertical)
                        .font(.headline)
                        .lineLimit(1...4)
                }

                Section {
                    ForEach(draft.options.indices, id: \.self) { index in
                        optionRow(index)
                    }
                    if draft.options.count < PollDraft.maxOptions {
                        Button {
                            draft.options.append("")
                            focusedOption = draft.options.count - 1
                        } label: {
                            Label("Add option", systemImage: "plus.circle.fill")
                        }
                    }
                } header: {
                    Text("Options")
                } footer: {
                    Text("At least two, up to \(PollDraft.maxOptions).")
                }

                Section {
                    Picker("Voters can pick", selection: $draft.type) {
                        Text("One").tag(NIP88Poll.PollType.single)
                        Text("Any").tag(NIP88Poll.PollType.multiple)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Voters can pick")
                }

                Section {
                    Picker("Voting closes", selection: $closes) {
                        ForEach(Closing.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if closes == .custom {
                        DatePicker("Closes", selection: $customEnd, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    }
                } footer: {
                    Text("Results show to everyone who has voted, and to all once voting closes.")
                }

                if let message = error ?? hint {
                    Section {
                        Text(message).foregroundColor(error == nil ? .secondary : .red)
                    }
                }
            }
            .disabled(isPosting)
            .navigationTitle("New poll")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                        .disabled(isPosting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isPosting {
                        ProgressView()
                    } else {
                        Button("Post") { publish() }
                            .fontWeight(.bold)
                            .disabled(!readyDraft.isComplete() || configService.activeAccountHexPubkey.isEmpty)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isPosting)
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 560, idealHeight: 640)
        #endif
    }

    private func optionRow(_ index: Int) -> some View {
        HStack {
            TextField("Option \(index + 1)", text: Binding(
                get: { draft.options.indices.contains(index) ? draft.options[index] : "" },
                set: { if draft.options.indices.contains(index) { draft.options[index] = $0 } }
            ))
            .focused($focusedOption, equals: index)
            .submitLabel(index == draft.options.count - 1 ? .done : .next)
            .onSubmit {
                if index + 1 < draft.options.count { focusedOption = index + 1 }
            }
            if draft.options.count > PollDraft.minOptions {
                Button {
                    focusedOption = nil
                    draft.options.remove(at: index)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove option \(index + 1)")
            }
        }
    }

    private func publish() {
        let ready = readyDraft
        guard ready.isComplete() else { return }
        isPosting = true
        error = nil
        let lock = ModePostPublisher.lockAccount(configService: configService)
        let relays = pollRelays
        Task {
            do {
                try await ModePostPublisher.publish(
                    kind: NIP88Poll.kind, content: ready.trimmedQuestion,
                    tags: ready.tags(relays: relays),
                    extraRelays: Array(relays.prefix(PollDraft.maxRelays)),
                    nostrService: nostrService,
                    lockedTo: lock)
                isPosting = false
                onDismiss()
            } catch {
                isPosting = false
                self.error = error.localizedDescription
                ErrorNotificationManager.shared.show(error.localizedDescription)
            }
        }
    }
}
