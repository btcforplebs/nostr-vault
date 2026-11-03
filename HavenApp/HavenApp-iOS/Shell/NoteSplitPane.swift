import SwiftUI
import UIKit

// MARK: - Note Split Pane

/// Column widths for [NoteSplitPane]. A separate type because static stored
/// properties are not allowed in a generic one.
private enum NoteSplitMetrics {
    /// Leaves a readable note column on the narrowest iPad in landscape.
    static let defaultList: Double = 380
    /// Floors, not preferences: below these a column stops being usable. The
    /// list floor is about one full note row; the detail floor is roughly the
    /// width at which a note's text stops wrapping into a readable measure.
    static let minList: Double = 280
    static let minDetail: Double = 360
    /// Narrower than this (a narrow Split View or Stage Manager window), the
    /// pane shows one column: the list, with a note opening over it.
    static let minSplit: Double = minList + minDetail + 14
}

/// iPad two-pane note layout, landscape only: the scrolling list on the left,
/// the selected note held open on the right, each in its own navigation stack
/// (`iPhoneTabView` puts the list's stack inside `content`). A list stack
/// around the whole pane would take the note's toolbar into its own bar,
/// across the top of both columns.
///
/// This is what separates an iPad layout from a stretched phone one. Without it
/// the list occupies the entire detail pane and tapping a note pushes the note
/// over all of it, so only one of the two things you are reading is ever on
/// screen. The pane publishes a `NoteDetailSelection` into the environment;
/// `NoteNavigationLink` and the views that open notes by id pick it up and
/// select instead of pushing.
struct NoteSplitPane<Content: View>: View {
    /// Placeholder shown in the detail column before anything is selected.
    let emptyTitle: String
    let emptyMessage: String
    /// Two columns are allowed (iPad landscape). When false the pane shows one
    /// column, a selected note covering the list, but stays the same view, so
    /// rotating never rebuilds the tab or drops a sheet opened inside it.
    var allowsTwoColumns: Bool = true
    @ViewBuilder var content: () -> Content

    @StateObject private var selection = NoteDetailSelection()

    /// Width of the list column, dragged by the reader and remembered across
    /// launches.
    @AppStorage("ipad.noteSplit.listWidth") private var listWidth: Double = NoteSplitMetrics.defaultList

    /// Width when the current drag began, so the column tracks the finger
    /// exactly instead of accelerating away from it (a drag reports total
    /// translation from its start, not a delta since the last callback).
    @State private var dragStartWidth: Double?

    /// A trackpad or mouse pointer is over the divider. iPadOS has no resize
    /// cursor (`PointerStyle.columnResize` is macOS-only), so the divider
    /// itself answers: it thickens and takes the accent while it can be dragged.
    @State private var isHandleHovered = false

    /// The reader folded the note column away to give the list the whole
    /// pane. Remembered across launches; opening a note brings the column back.
    @AppStorage("ipad.noteSplit.detailHidden") private var detailHidden = false

    var body: some View {
        GeometryReader { geo in
            // The ceiling depends on the pane's real width, which changes with
            // Split View and Stage Manager. Clamping on read
            // means a width saved on a wide layout can't strand the detail
            // column off-screen on a narrow one — and it is restored, not
            // overwritten, when there is room again.
            let maxListWidth = max(NoteSplitMetrics.minList, geo.size.width - NoteSplitMetrics.minDetail)
            let width = min(max(listWidth, NoteSplitMetrics.minList), maxListWidth)

            // Portrait, or too narrow for two columns (a narrow window):
            // the list fills the pane and a selected note covers it, with
            // Back to return, the way the phone pushes one. The list keeps
            // its place in the hierarchy either way, so crossing the width
            // keeps its scroll position and the open note.
            let singleColumn = !allowsTwoColumns || geo.size.width < NoteSplitMetrics.minSplit
            let showsDetailColumn = !singleColumn && !detailHidden

            HStack(spacing: 0) {
                content()
                    .frame(width: showsDetailColumn ? width : geo.size.width)
                    .environment(\.noteDetailSelection, selection)

                if showsDetailColumn {
                    resizeHandle(maxListWidth: maxListWidth)
                        // The fold tab is wider than the handle; keep the
                        // detail column from drawing over (and taking taps
                        // from) the half that overhangs it.
                        .zIndex(1)

                    detailColumn(showsBack: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.move(edge: .trailing))
                }
            }
            // GeometryReader hands its child the full space but does not force
            // it to fill: without this the row sizes to its content and the
            // handle has nothing to span.
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .trailing) {
                if !singleColumn && detailHidden {
                    detailToggle
                }
            }
            .overlay {
                if singleColumn && !selection.isEmpty {
                    detailColumn(showsBack: true)
                        .background(Color.platformWindowBackground)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(singleColumn ? .easeInOut(duration: 0.25) : nil, value: selection.isEmpty)
            .clipped()
        }
        .onChange(of: selection.note?.id) { _, id in
            if id != nil { setDetailHidden(false) }
        }
        .onChange(of: selection.noteId) { _, id in
            if id != nil { setDetailHidden(false) }
        }
    }

    private func setDetailHidden(_ hidden: Bool) {
        guard hidden != detailHidden else { return }
        withAnimation(.easeInOut(duration: 0.25)) { detailHidden = hidden }
    }

    /// The tab that folds the note column away, or brings it back. It sits on
    /// the divider while the column is open and on the pane's trailing edge
    /// while it is folded, vertically centred so it stays clear of the
    /// navigation bar, which would otherwise take its taps.
    private var detailToggle: some View {
        Button {
            setDetailHidden(!detailHidden)
        } label: {
            Image(systemName: detailHidden ? "chevron.left" : "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 56)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.trailing, detailHidden ? 4 : 0)
        .accessibilityLabel(detailHidden ? "Show note" : "Hide note")
    }

    /// The draggable divider. A plain `Divider()` is one hairline wide and
    /// cannot be hit with a finger, so the visible line stays hairline while the
    /// gesture is attached to 14pt of clear space around it, with a grip so the
    /// column is discoverably resizable rather than secretly so.
    private func resizeHandle(maxListWidth: Double) -> some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(isHandleActive ? Color.havenPurple : Color(uiColor: .separator))
                .frame(width: isHandleActive ? 3 : 1)
                .animation(.easeOut(duration: 0.12), value: isHandleActive)
            // The fold tab doubles as the drag grip's centre mark.
            detailToggle
        }
        .frame(width: 14)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isHandleHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStartWidth ?? listWidth
                    dragStartWidth = start
                    listWidth = min(max(start + value.translation.width, NoteSplitMetrics.minList), maxListWidth)
                }
                .onEnded { _ in dragStartWidth = nil }
        )
        .onTapGesture(count: 2) { listWidth = NoteSplitMetrics.defaultList }
        .accessibilityLabel("Resize note list")
        .accessibilityHint("Drag to change the width of the list. Double tap to reset.")
    }

    /// Hovered by the pointer, or being dragged.
    private var isHandleActive: Bool { isHandleHovered || dragStartWidth != nil }

    @ViewBuilder
    private func detailColumn(showsBack: Bool) -> some View {
        if let note = selection.note {
            // No selection injected here on purpose: links inside the detail
            // column push onto its own stack rather than replacing the note the
            // reader is looking at.
            NavigationStack {
                Group {
                    // A long-form event opens in the reader, not as a note. This is
                    // what makes tapping an Articles card do something on iPad.
                    if note.kind == 30023 {
                        ArticleReaderView(note: note)
                            .environmentObject(NostrService.shared)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbarBackground(.hidden, for: .navigationBar)
                    } else {
                        NoteDetailView(note: note)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .navigationDestination(for: FeedNote.self) { pushed in
                            NoteDetailView(note: pushed)
                        }
                    }
                }
                .toolbar {
                    if showsBack {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { selection.clear() } label: {
                                Label("Back", systemImage: "chevron.left")
                            }
                        }
                    }
                }
            }
            .id(note.id)
        } else if let noteId = selection.noteId {
            NoteDetailViewWrapper(noteId: noteId, onDismiss: { selection.clear() })
                .environmentObject(NostrService.shared)
                .environmentObject(ConfigService.shared)
                .id(noteId)
        } else {
            ContentUnavailableView(
                emptyTitle,
                systemImage: "text.bubble",
                description: Text(emptyMessage)
            )
        }
    }
}
