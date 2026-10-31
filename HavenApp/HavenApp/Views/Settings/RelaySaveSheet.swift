import SwiftUI

/// The confirm step of Settings > Relays: what Save publishes and what stays
/// on this device, list by list. Twin of Android `RelayMatrixScreen.kt`'s SaveSheet.
struct RelaySaveSheet: View {
    let plan: RelayDraft.Plan
    let changes: Int
    let save: () -> Void
    /// False in setup's Change sheet: the key isn't stored yet, and setup publishes on Continue.
    var hasAccount = true

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                group("Relay list (10002)", plan.relayListChanges, held: plan.relayListHeld,
                      note: plan.relayListTags != nil ? "Read and Write from Yours. Signed with your key and sent to your relays." : nil)
                group("DM inbox (10050)", plan.dmChanges, held: plan.dmListHeld,
                      note: plan.dmRelays != nil ? "DMs from Yours. Signed with your key and sent to your relays." : nil)
                group("On this device only", plan.localChanges, held: false,
                      note: "App defaults, Search and Import. Never published.")
                Section {
                    Button {
                        save()
                        dismiss()
                    } label: {
                        Text(plan.publishes ? "Save and Publish" : "Save on This Device")
                            .font(.appBody.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.havenPurple)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Nothing else on your lists is touched.")
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("Save \(RelaySaveSheet.changesLabel(changes))?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep Editing") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    private func group(_ title: String, _ changes: [RelayDraft.Change], held: Bool, note: String?) -> some View {
        Section {
            if changes.isEmpty {
                Text("Nothing changes").font(.appCaption).foregroundColor(.secondary)
            }
            ForEach(changes) { change in
                VStack(alignment: .leading, spacing: 2) {
                    Text(RelayMatrix.label(change.url)).font(.appBody).lineLimit(1).truncationMode(.middle)
                    Text(Self.describe(change)).font(.appCaption).foregroundColor(.secondary)
                }
            }
        } header: {
            Text(title)
        } footer: {
            if held && !hasAccount {
                Text("Saved on this device. Setup publishes your Write relays when you tap Continue.")
            } else if held {
                Text("Not published: your relays didn't send your current list, and publishing could replace one set in another app. Saved on this device.")
                    .foregroundColor(.orange)
            } else if let note, !changes.isEmpty {
                Text(note)
            }
        }
    }

    static func describe(_ change: RelayDraft.Change) -> String {
        func names(_ jobs: Set<RelayMatrix.Job>) -> String {
            RelayMatrix.Job.allCases.filter(jobs.contains).map(\.title).joined(separator: ", ")
        }
        var parts: [String] = []
        if !change.added.isEmpty { parts.append("+ \(names(change.added))") }
        if !change.removed.isEmpty { parts.append("− \(names(change.removed))") }
        return parts.joined(separator: "   ")
    }

    static func changesLabel(_ count: Int) -> String {
        count == 1 ? "1 change" : "\(count) changes"
    }
}
