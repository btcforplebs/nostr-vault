import SwiftUI

struct DraftPickerView: View {
    @StateObject private var draftService = DraftService.shared
    let onSelect: (Draft) -> Void
    let onDelete: (Draft) -> Void
    @Environment(\.dismiss) var dismiss

    /// Selection mode is driven by plain state rather than SwiftUI's EditMode so
    /// the same code path works on macOS, where EditMode doesn't exist.
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var confirmingBulkDelete = false

    private var filteredDrafts: [Draft] {
        draftService.draftsForActiveAccount
    }

    private var selectedDrafts: [Draft] {
        filteredDrafts.filter { selectedIDs.contains($0.id) }
    }

    private func toggleSelection(_ draft: Draft) {
        if selectedIDs.contains(draft.id) {
            selectedIDs.remove(draft.id)
        } else {
            selectedIDs.insert(draft.id)
        }
    }

    private func exitSelection() {
        isSelecting = false
        selectedIDs.removeAll()
    }

    private func deleteSelected() {
        // Snapshot first: onDelete mutates the service's published list, so
        // iterating selectedDrafts directly would walk a collection being
        // rebuilt underneath us.
        for draft in selectedDrafts {
            onDelete(draft)
        }
        exitSelection()
    }

    var body: some View {
        NavigationStack {
            Group {
                if draftService.isLoading && filteredDrafts.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        Text("Loading drafts...")
                            .font(.appSystem(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredDrafts.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text")
                            .font(.appSystem(size: 48, weight: .thin))
                            .foregroundColor(Color.havenPurple.opacity(0.6))
                        Text("No drafts")
                            .font(.appSystem(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(filteredDrafts) { draft in
                            Button {
                                if isSelecting {
                                    toggleSelection(draft)
                                } else {
                                    onSelect(draft)
                                    dismiss()
                                }
                            } label: {
                                HStack(spacing: 12) {
                                if isSelecting {
                                    Image(systemName: selectedIDs.contains(draft.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.appSystem(size: 20))
                                        .foregroundColor(selectedIDs.contains(draft.id) ? .havenPurple : .secondary.opacity(0.5))
                                        .transition(.opacity)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    if draft.isReply {
                                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                                            .font(.appCaption)
                                            .foregroundColor(.havenPurple)
                                        DraftReplyParentLine(draft: draft)
                                    } else if draft.isQuote {
                                        Label("Quote", systemImage: "quote.bubble")
                                            .font(.appCaption)
                                            .foregroundColor(.havenPurple)
                                    } else {
                                        Label("Post", systemImage: "square.and.pencil")
                                            .font(.appCaption)
                                            .foregroundColor(.secondary)
                                    }

                                    Text(draft.preview)
                                        .font(.appSystem(size: 14))
                                        .foregroundColor(.primary)
                                        .lineLimit(2)

                                    Text(draft.updatedAt, style: .relative)
                                        .font(.appCaption2)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            // Swipe-to-delete stays available outside selection
                            // mode; inside it the swipe would fight the tap.
                            .swipeActions(edge: .trailing) {
                                if !isSelecting {
                                    Button(role: .destructive) {
                                        onDelete(draft)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #else
                    .listStyle(.inset)
                    #endif
                }
            }
            .background(Color.platformSecondaryGroupedBackground)
            .navigationTitle("Drafts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isSelecting {
                        Button("Done") { exitSelection() }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !filteredDrafts.isEmpty {
                        if isSelecting {
                            Button {
                                if selectedIDs.count == filteredDrafts.count {
                                    selectedIDs.removeAll()
                                } else {
                                    selectedIDs = Set(filteredDrafts.map(\.id))
                                }
                            } label: {
                                Text(selectedIDs.count == filteredDrafts.count ? "Deselect All" : "Select All")
                            }
                        } else {
                            Button("Select") { isSelecting = true }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    HStack {
                        Text(selectedIDs.isEmpty
                             ? "Select drafts to delete"
                             : "\(selectedIDs.count) selected")
                            .font(.appSystem(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            confirmingBulkDelete = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .font(.appSystem(size: 14, weight: .semibold))
                        }
                        .disabled(selectedIDs.isEmpty)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                }
            }
            .confirmationDialog(
                selectedIDs.count == 1 ? "Delete this draft?" : "Delete \(selectedIDs.count) drafts?",
                isPresented: $confirmingBulkDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deleted drafts are removed from your relay and can't be recovered.")
            }
        }
        .onAppear {
            Task { await draftService.fetchDrafts() }
        }
    }
}

/// "↩ name: first line of their note" under a reply draft's chip. Loads the
/// note (and its author's profile) when it isn't in memory yet; old drafts too.
private struct DraftReplyParentLine: View {
    let draft: Draft
    @ObservedObject private var feed = FeedService.shared
    @ObservedObject private var nostr = NostrService.shared

    var body: some View {
        if let id = draft.replyToId {
            let parent = feed.findNote(id: id)
            let pubkey = parent?.pubkey ?? draft.parentPubkey
            let name = pubkey.flatMap { nostr.profiles[$0]?.bestName } ?? pubkey.map { String($0.prefix(8)) } ?? "someone"
            Text(DraftReplyParent.line(name: name, parentContent: parent?.content))
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .task(id: id) {
                    if let pk = pubkey, nostr.profiles[pk] == nil { nostr.fetchMissingProfiles(for: [pk]) }
                    guard feed.findNote(id: id) == nil, let note = await DraftParentLoader.load(id) else { return }
                    if nostr.profiles[note.pubkey] == nil { nostr.fetchMissingProfiles(for: [note.pubkey]) }
                }
        }
    }
}
