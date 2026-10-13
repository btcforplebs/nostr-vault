import SwiftUI

/// The saved drafts of one kind (articles, recipes or polls), opened from the
/// composer. Picking one loads it into the composer; swiping deletes it.
struct ComposerDraftsSheet: View {
    @ObservedObject var keeper: ComposerDraftKeeper
    let onSelect: (ComposerDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if keeper.others.isEmpty {
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
                        ForEach(keeper.others) { draft in
                            Button {
                                onSelect(draft)
                                dismiss()
                            } label: {
                                row(draft)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    keeper.delete(draft)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    keeper.delete(draft)
                                } label: {
                                    Label("Delete Draft", systemImage: "trash")
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
            .navigationTitle(keeper.kind.listTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    private func row(_ draft: ComposerDraft) -> some View {
        HStack(spacing: 12) {
            thumbnail(draft)
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.previewTitle)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if !draft.previewDetail.isEmpty {
                    Text(draft.previewDetail)
                        .font(.appSystem(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Text(draft.updatedAt, style: .relative)
                    .font(.appCaption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this draft")
    }

    @ViewBuilder
    private func thumbnail(_ draft: ComposerDraft) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if let data = ComposerDraftStore.shared.cover(for: draft, account: keeper.account),
           let image = Self.image(from: data) {
            image
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(shape)
                .accessibilityHidden(true)
        } else {
            shape
                .fill(Color.havenPurplePale)
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: Self.symbol(for: draft.kind))
                        .foregroundColor(.havenPurple.opacity(0.8))
                }
                .accessibilityHidden(true)
        }
    }

    private static func symbol(for kind: ComposerDraft.Kind) -> String {
        switch kind {
        case .article: return "doc.richtext"
        case .recipe: return "fork.knife"
        case .poll: return "chart.bar.xaxis"
        }
    }

    private static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #else
        return NSImage(data: data).map { Image(nsImage: $0) }
        #endif
    }
}

/// The row at the top of a composer that opens its saved drafts. Shown only
/// when there are some, so a first-time composer stays uncluttered.
struct ComposerDraftsRow: View {
    @ObservedObject var keeper: ComposerDraftKeeper
    let action: () -> Void

    var body: some View {
        if !keeper.others.isEmpty {
            Section {
                Button(action: action) {
                    HStack {
                        Label(keeper.others.count == 1 ? "1 saved draft" : "\(keeper.others.count) saved drafts",
                              systemImage: "tray.full")
                            .foregroundColor(.havenPurple)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
