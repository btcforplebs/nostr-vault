import SwiftUI

/// Event Info: who posted an event and when, which relays have it, and what
/// you can do with it (copy, share, re-broadcast). The relay lookup and the
/// signature check live in `EventInspector`; this view only draws them.
struct EventBroadcastSheet: View {
    let note: FeedNote
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.dismiss) var dismiss

    @StateObject private var inspector: EventInspector

    /// Relays ticked to receive the next re-broadcast.
    @State private var selectedRelays: Set<String> = []
    @State private var didSeedSelection = false
    @State private var isBroadcasting = false
    @State private var pendingRelays = Set<String>()
    /// Bumped per broadcast so an older send's backstop can't touch a newer one.
    @State private var broadcastRound = 0
    /// Each relay's answer to the last broadcast: accepted, and its message.
    @State private var broadcastResults: [String: BroadcastResult] = [:]
    @State private var showRawEvent = false
    @State private var copiedAction: String?

    private struct BroadcastResult {
        let ok: Bool
        let message: String
    }

    init(note: FeedNote) {
        self.note = note
        _inspector = StateObject(wrappedValue: EventInspector(note: note))
    }

    private var shareURL: String { "https://mynostrspace.com/thread/\(note.nevent)" }

    private var authorNpub: String {
        guard let data = Bech32.hexToData(note.pubkey),
              let npub = Bech32.encode(hrp: "npub", data: data) else { return note.pubkey }
        return npub
    }

    private var eventJSON: String {
        let dict: [String: Any] = inspector.event ?? [
            "id": note.id,
            "pubkey": note.pubkey,
            "created_at": Int(note.createdAt.timeIntervalSince1970),
            "kind": note.kind,
            "tags": note.tags,
            "content": note.content
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    summaryCard
                    actionsRow
                    relaysSection
                    detailsSection
                }
                .padding()
            }
            .navigationTitle("Event Info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .background(Color.platformControlBackground)
        .onAppear {
            inspector.start()
            if !didSeedSelection {
                selectedRelays = Set(inspector.defaultBroadcastRelays)
                didSeedSelection = true
            }
            nostrService.fetchMissingProfiles(for: [note.pubkey] + [note.repostedBy].compactMap { $0 })
        }
    }

    // MARK: - Summary

    private func displayName(_ pubkey: String) -> String {
        nostrService.profiles[pubkey]?.bestName ?? "npub…" + String(pubkey.suffix(6))
    }

    private var summaryCard: some View {
        let profile = nostrService.profiles[note.pubkey]
        let handle = profile?.nip05.flatMap { $0.isEmpty ? nil : $0 } ?? authorNpub
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AvatarView(url: profile?.pictureURL, pubkey: note.pubkey, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(note.pubkey))
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(handle)
                        .font(.appSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            Divider()

            VStack(spacing: 10) {
                factRow("Kind") {
                    Text("\(kindName) · \(note.kind)")
                }
                factRow("Posted") {
                    Text(note.createdAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                }
                if let reposter = note.repostedBy {
                    factRow("Reposted by") {
                        Text(displayName(reposter))
                    }
                }
                factRow("Signature") { signatureBadge }
            }
        }
        .padding(14)
        .background(Color.platformTertiaryGroupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var kindName: String {
        NostrEvent(id: note.id, pubkey: note.pubkey, created_at: 0, kind: note.kind,
                   tags: [], content: "", sig: "").kindDescription
    }

    private func factRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.appSystem(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            value()
                .font(.appSystem(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var signatureBadge: some View {
        switch inspector.signature {
        case .valid:
            Label("Valid", systemImage: "checkmark.seal.fill")
                .foregroundColor(.green)
        case .invalid:
            Label("Invalid", systemImage: "xmark.seal.fill")
                .foregroundColor(.red)
        case .unknown:
            if inspector.isFetching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking")
                }
                .foregroundColor(.secondary)
            } else {
                Label("Couldn't check", systemImage: "questionmark.circle")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Actions

    private var actionsRow: some View {
        HStack(spacing: 8) {
            actionButton("Copy link", icon: "link", id: "link") { copyToClipboard(shareURL) }

            if let url = URL(string: shareURL) {
                ShareLink(item: url) {
                    actionTile("Share", icon: "square.and.arrow.up", copied: false)
                }
                .buttonStyle(.plain)
            }

            actionButton("Copy npub", icon: "person.crop.circle", id: "npub") { copyToClipboard(authorNpub) }

            actionButton("Copy JSON", icon: "curlybraces", id: "json") { copyToClipboard(eventJSON) }
                .disabled(inspector.event == nil)
                .opacity(inspector.event == nil ? 0.45 : 1)
        }
    }

    private func actionButton(_ title: String, icon: String, id: String, perform: @escaping () -> Void) -> some View {
        Button {
            perform()
            withAnimation(Motion.pop) { copiedAction = id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedAction == id { withAnimation(Motion.fade) { copiedAction = nil } }
            }
        } label: {
            actionTile(title, icon: icon, copied: copiedAction == id)
        }
        .buttonStyle(.plain)
    }

    private func actionTile(_ title: String, icon: String, copied: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: copied ? "checkmark" : icon)
                .font(.appSystem(size: 16, weight: .medium))
                .foregroundColor(copied ? .green : Color.havenPurple)
                .frame(height: 20)
            Text(copied ? "Copied" : title)
                .font(.appSystem(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.platformTertiaryGroupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(copied ? "\(title), copied" : title)
    }

    // MARK: - Relays

    private var foundCount: Int {
        inspector.relays.filter { inspector.presence[$0] == .found }.count
    }

    private var missingRelays: [String] {
        inspector.relays.filter { inspector.presence[$0] == .notFound }
    }

    private var relaysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                sectionHeader("RELAYS")
                Spacer()
                if inspector.isFetching {
                    ProgressView().controlSize(.mini)
                }
                Text("On \(foundCount) of \(inspector.relays.count)")
                    .font(.appSystem(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .contentTransition(.numericText())
                    .animation(Motion.fade, value: foundCount)
            }

            VStack(spacing: 0) {
                ForEach(Array(inspector.relays.enumerated()), id: \.element) { index, relay in
                    if index > 0 { Divider().padding(.leading, 40) }
                    relayRow(relay)
                }
            }
            .background(Color.platformTertiaryGroupedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                Text("Tick the relays to send to.")
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if !missingRelays.isEmpty {
                    Button("Select missing (\(missingRelays.count))") {
                        withAnimation(Motion.toggle) { selectedRelays.formUnion(missingRelays) }
                    }
                    .font(.appSystem(size: 12, weight: .medium))
                    .foregroundColor(Color.havenPurple)
                    .buttonStyle(.plain)
                    .disabled(isBroadcasting)
                }
            }

            broadcastButton
        }
    }

    private func relayRow(_ relay: String) -> some View {
        let isSelected = selectedRelays.contains(relay)
        let label = EventInspector.label(for: relay)
        return HStack(spacing: 12) {
            HStack(spacing: 12) {
                presenceIcon(for: relay)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.appSystem(size: 13, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    relayDetail(for: relay)
                        .font(.appSystem(size: 11))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            Button {
                withAnimation(Motion.toggle) {
                    if isSelected { selectedRelays.remove(relay) } else { selectedRelays.insert(relay) }
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.appSystem(size: 20))
                    .foregroundColor(isSelected ? Color.havenPurple : Color.secondary.opacity(0.5))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBroadcasting)
            .accessibilityLabel("Send to \(label)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func presenceIcon(for relay: String) -> some View {
        if pendingRelays.contains(relay) {
            ProgressView().controlSize(.mini)
        } else {
            switch inspector.presence[relay] ?? .checking {
            case .checking:
                ProgressView().controlSize(.mini)
            case .found:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .notFound:
                Image(systemName: "circle.dashed").foregroundColor(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
            }
        }
    }

    /// The last broadcast's answer wins over the lookup: it is newer.
    @ViewBuilder
    private func relayDetail(for relay: String) -> some View {
        if pendingRelays.contains(relay) {
            Text("Sending…").foregroundColor(.secondary)
        } else if let result = broadcastResults[relay] {
            if result.ok {
                Text("Sent").foregroundColor(.green)
            } else {
                Text("Rejected: \(result.message.isEmpty ? "failed" : result.message)").foregroundColor(.red)
            }
        } else {
            switch inspector.presence[relay] ?? .checking {
            case .checking: Text("Checking…").foregroundColor(.secondary)
            case .found: Text("Has it").foregroundColor(.secondary)
            case .notFound: Text("Doesn't have it").foregroundColor(.secondary)
            case .failed(let reason): Text("Couldn't check: \(reason)").foregroundColor(.orange)
            }
        }
    }

    private var broadcastButton: some View {
        let count = selectedRelays.count
        let disabled = isBroadcasting || inspector.event == nil || count == 0
        return Button {
            broadcast()
        } label: {
            HStack(spacing: 8) {
                if isBroadcasting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                Text(broadcastTitle(count: count))
            }
            .font(.appSystem(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(disabled ? Color.secondary.opacity(0.4) : Color.havenPurple)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func broadcastTitle(count: Int) -> String {
        if isBroadcasting { return "Sending…" }
        if inspector.event == nil {
            return inspector.isFetching ? "Finding the signed event…" : "No signed copy to send"
        }
        if count == 0 { return "Pick a relay" }
        return count == 1 ? "Broadcast to 1 relay" : "Broadcast to \(count) relays"
    }

    private func broadcast() {
        // Selected relays the lookup didn't list (none today) still go out.
        let listed = inspector.relays.filter { selectedRelays.contains($0) }
        let targets = listed + selectedRelays.subtracting(listed).sorted()
        guard !targets.isEmpty else { return }
        isBroadcasting = true
        broadcastRound += 1
        let round = broadcastRound
        pendingRelays = Set(targets)
        for relay in targets { broadcastResults[relay] = nil }

        inspector.broadcast(to: targets) { relay, ok, message in
            withAnimation(Motion.fade) {
                pendingRelays.remove(relay)
                broadcastResults[relay] = BroadcastResult(ok: ok, message: message)
                if pendingRelays.isEmpty { isBroadcasting = false }
            }
        }

        // A relay stuck connecting never reports back; don't leave it spinning.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            guard round == broadcastRound, !pendingRelays.isEmpty else { return }
            withAnimation(Motion.fade) {
                for relay in pendingRelays {
                    broadcastResults[relay] = BroadcastResult(ok: false, message: "no answer")
                }
                pendingRelays.removeAll()
                isBroadcasting = false
            }
        }
    }

    // MARK: - Details

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("IDENTIFIERS")
            CopyableRow(label: "hex", value: note.id)
            CopyableRow(label: "note1", value: note.note1)
            CopyableRow(label: "nevent", value: note.nevent)
            CopyableRow(label: "share link", value: shareURL)

            Button {
                withAnimation(Motion.toggle) { showRawEvent.toggle() }
            } label: {
                HStack {
                    sectionHeader("RAW EVENT")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.appSystem(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showRawEvent ? 90 : 0))
                }
                .padding(.top, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showRawEvent ? "Hide raw event" : "Show raw event")

            if showRawEvent {
                Text(eventJSON)
                    .font(.appSystem(size: 11, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.85))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.platformTertiaryGroupedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .textSelection(.enabled)
                    .transition(.opacity)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.secondary)
            .tracking(0.5)
            .accessibilityAddTraits(.isHeader)
    }

    private func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
struct CopyableRow: View {
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.appSystem(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.appSystem(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                copy()
                withAnimation(Motion.pop) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.appSystem(size: 13))
                    .foregroundColor(copied ? .green : Color.havenPurple)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.platformTertiaryGroupedBackground)
        .cornerRadius(8)
    }

    private func copy() {
        #if os(iOS)
        UIPasteboard.general.string = value
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}
