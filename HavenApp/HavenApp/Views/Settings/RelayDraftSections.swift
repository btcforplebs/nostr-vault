import SwiftUI

/// The Your Relays page of Settings > Relays (option A): "Yours" with the
/// vault's own relay pinned on top, then "App defaults". Rows keep the order
/// fixed when the screen opened (`RelayDraft.State.layout`).
struct RelayDraftSections: View {
    let draft: RelayDraft.State?
    let rows: [RelayDraft.Row]
    let ownRow: AnyView?
    let result: (String) -> RelayProbe.Result?
    let open: (RelayDraft.Row) -> Void
    let toggle: (String, RelayMatrix.Job) -> Void
    let remove: (String) -> Void
    let undo: (String) -> Void

    var body: some View {
        if let draft {
            if draft.published.hasAccount, !draft.published.relayListKnown || !draft.published.dmListKnown {
                Section {
                    Label {
                        Text("Your \(unknownLists(draft.published)) didn't load. Edits to \(draft.published.relayListKnown || draft.published.dmListKnown ? "it" : "them") are kept on this device and not published.")
                            .font(.appCaption)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    }
                }
            }
            Section {
                ownRow
                let mine = rows.filter { $0.entry.section == .yours }
                ForEach(mine) { row($0) }
                if mine.isEmpty {
                    Text(draft.published.relayListKnown
                         ? "No published relay list yet. Tap + to add a relay, then Save."
                         : draft.published.hasAccount ? "Nothing loaded yet." : "Your new account has no relay list yet.")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            } header: {
                RelayJobHeader(title: "Yours · your relay list and DM inbox")
            } footer: {
                Text("Read and Write are your relay list (10002), DMs your DM inbox (10050). Save publishes them.")
            }
            Section {
                let defaults = rows.filter { $0.entry.section == .defaults }
                ForEach(defaults) { row($0) }
                if defaults.isEmpty {
                    Text("None.").font(.appCaption).foregroundColor(.secondary)
                }
            } header: {
                RelayJobHeader(title: "App defaults · this device only")
            } footer: {
                Text("Added by Nostr Vault so it works out of the box. Used on this device only, never published. Remove any you don't want.")
            }
        } else {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading your relay lists…").font(.appCaption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func row(_ row: RelayDraft.Row) -> some View {
        RelayDraftRowView(
            row: row, result: result(row.url),
            open: { open(row) },
            toggle: { toggle(row.id, $0) },
            remove: { remove(row.id) },
            undo: { undo(row.id) })
    }

    private func unknownLists(_ published: RelayDraft.Published) -> String {
        [published.relayListKnown ? nil : "relay list", published.dmListKnown ? nil : "DM inbox"]
            .compactMap { $0 }.joined(separator: " and ")
    }
}
