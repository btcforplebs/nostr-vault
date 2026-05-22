import SwiftUI
import Combine

struct EventBroadcastSheet: View {
    let note: FeedNote
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) var dismiss

    @State private var fullEventDict: [String: Any]?
    @State private var isFetchingEvent = true
    @State private var isBroadcasting = false
    @State private var broadcastResult: String?
    @State private var cancellables = Set<AnyCancellable>()

    private var eventJSON: String {
        let dict: [String: Any]
        if let full = fullEventDict {
            dict = full
        } else {
            dict = [
                "id": note.id,
                "pubkey": note.pubkey,
                "created_at": Int(note.createdAt.timeIntervalSince1970),
                "kind": note.kind,
                "tags": note.tags,
                "content": note.content
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    eventIdSection
                    Divider()
                    jsonSection
                    Divider()
                    broadcastSection
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
        .onAppear { fetchFullEvent() }
    }

    private var eventIdSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EVENT ID")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .tracking(0.5)

            CopyableRow(label: "hex", value: note.id)
            CopyableRow(label: "note1", value: note.note1)
            CopyableRow(label: "nevent", value: note.nevent)
            CopyableRow(label: "share link", value: "https://mynostrspace.com/thread/\(note.nevent)")
        }
    }

    private var jsonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RAW EVENT")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .tracking(0.5)

                Spacer()

                if isFetchingEvent {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.havenPurple)
                } else {
                    Button {
                        copyToClipboard(eventJSON)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color.havenPurple)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(eventJSON)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary.opacity(0.85))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.platformTertiaryGroupedBackground)
                .cornerRadius(8)
                .textSelection(.enabled)
        }
    }

    private var broadcastSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BROADCAST")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .tracking(0.5)

            let blastrRelays = configService.config.blastrRelays.isEmpty
                ? ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"]
                : configService.config.blastrRelays

            VStack(alignment: .leading, spacing: 6) {
                Text("Broadcasting to \(blastrRelays.count) relay(s):")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)

                ForEach(blastrRelays.prefix(6), id: \.self) { relay in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.havenPurple.opacity(0.5))
                            .frame(width: 4, height: 4)
                        Text(relay)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                if blastrRelays.count > 6 {
                    Text("+ \(blastrRelays.count - 6) more")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .padding(10)
            .background(Color.platformTertiaryGroupedBackground)
            .cornerRadius(8)

            if let result = broadcastResult {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(result)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.green)
                }
            }

            Button {
                broadcastNote()
            } label: {
                HStack(spacing: 8) {
                    if isBroadcasting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    Text(isBroadcasting ? "Broadcasting..." : "Re-Broadcast Event")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(isBroadcasting || fullEventDict == nil
                    ? Color.secondary.opacity(0.4)
                    : Color.havenPurple)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(isBroadcasting || fullEventDict == nil)
        }
    }

    private func fetchFullEvent() {
        guard let localURL = URL(string: configService.config.nostrURL) else {
            isFetchingEvent = false
            return
        }

        let client = WebSocketClient()
        client.isTemporary = true

        client.messageSubject
            .receive(on: DispatchQueue.main)
            .sink { msg in
                guard let data = msg.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                      let type = json[0] as? String,
                      type == "EVENT", json.count >= 3,
                      let ev = json[2] as? [String: Any] else { return }
                self.fullEventDict = ev
                self.isFetchingEvent = false
                client.disconnect()
            }
            .store(in: &cancellables)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { state in
                if state == .connected {
                    let filter: [String: Any] = ["ids": [self.note.id], "limit": 1]
                    let req = ["REQ", "broadcast-fetch-\(UUID().uuidString.prefix(8))", filter] as [Any]
                    if let data = try? JSONSerialization.data(withJSONObject: req),
                       let str = String(data: data, encoding: .utf8) {
                        client.send(text: str)
                    }
                }
            }
            .store(in: &cancellables)

        client.connect(url: localURL)

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.isFetchingEvent = false
        }
    }

    private func broadcastNote() {
        guard let eventDict = fullEventDict else { return }
        isBroadcasting = true
        broadcastResult = nil
        nostrService.broadcastRawEvent(eventDict)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isBroadcasting = false
            broadcastResult = "Broadcast sent to relays"
        }
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
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                copy()
                withAnimation(.spring(response: 0.2)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13))
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
