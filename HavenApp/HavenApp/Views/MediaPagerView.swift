import SwiftUI

/// Cross-platform image/media pager.
///
/// `TabView(selection:)` with `.page` style doesn't exist on macOS (Apple never shipped
/// it there), and macOS's default `.automatic` TabViewStyle draws an unlabelled tab strip
/// instead of a pager — there's no public way to restyle or suppress that chrome from
/// outside the view that builds it, so this owns the platform split itself rather than
/// being a modifier bolted onto someone else's `TabView`.
struct MediaPagerView<Item: Hashable, ItemContent: View>: View {
    let items: [Item]
    let content: (Item) -> ItemContent

    /// Opts into `.focusable()` + left/right arrow-key navigation. Only the full-screen,
    /// one-note-at-a-time viewers (profile media viewer, media gallery viewer, the feed's
    /// grid media viewer) set this to `true`. Inline carousels embedded in scrolling rows
    /// (feed rows, vault rows, reposted notes) always call `MediaPagerView` with more than
    /// one item already — gating on `items.count > 1` alone wouldn't stop every media row
    /// in a list from becoming a silent keyboard tab stop, so those call sites simply leave
    /// this off and rely on the always-visible tap-target arrow buttons instead.
    var enableKeyboardNavigation: Bool = false

    private let externalSelection: Binding<Item?>?
    @State private var localSelection: Item?

    /// Index-based identity for the current page. `selection` (an `Item`) is still exposed
    /// to callers for compatibility with existing bindings, but paging itself is driven off
    /// this index so two pages sharing the same value (a note repeating the same image URL)
    /// can't collide the way a `firstIndex(of:)` value lookup would.
    @State private var index: Int?

    init(
        items: [Item],
        selection: Binding<Item?>? = nil,
        enableKeyboardNavigation: Bool = false,
        @ViewBuilder content: @escaping (Item) -> ItemContent
    ) {
        self.items = items
        self.externalSelection = selection
        self.enableKeyboardNavigation = enableKeyboardNavigation
        self.content = content
        if selection == nil {
            self._localSelection = State(initialValue: items.first)
        }
    }

    private var selectionBinding: Binding<Item?> {
        externalSelection ?? Binding(
            get: { localSelection },
            set: { localSelection = $0 }
        )
    }

    /// The index used to drive paging on both platforms. Writing to it also writes the
    /// corresponding item into `selectionBinding`, keeping the external `Item?` contract in
    /// sync without ever routing an internal step through a value-based lookup.
    private var indexBinding: Binding<Int?> {
        Binding(
            get: { index },
            set: { newIndex in
                index = newIndex
                if let newIndex, items.indices.contains(newIndex) {
                    selectionBinding.wrappedValue = items[newIndex]
                }
            }
        )
    }

    var body: some View {
        pagerBody
            #if os(iOS)
            // iOS propagates a container value down onto the page content, which is a
            // reasonable place for the position. macOS drops `value` on AXGroup/AXUnknown
            // and propagates it onto every child element instead — verified with an
            // AXUIElement probe, where both arrow buttons ended up announcing
            // "Image 1 of 3" and no element carried the pager's own position. There the
            // position lives in the dots' *label*; see `pageDots`.
            .accessibilityValue(items.isEmpty ? "" : "Image \((index ?? 0) + 1) of \(items.count)")
            #endif
            .onAppear { syncIndexOnAppear() }
            .onChange(of: items) { _, newItems in reconcile(after: newItems) }
    }

    @ViewBuilder
    private var pagerBody: some View {
        #if os(iOS)
        TabView(selection: indexBinding) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                content(item).tag(offset as Int?)
            }
        }
        // Dots hidden so the viewer stays clean; callers show their own position UI where needed.
        .tabViewStyle(.page(indexDisplayMode: .never))
        #else
        MacMediaPager(items: items, index: indexBinding, enableKeyboardNavigation: enableKeyboardNavigation, content: content)
        #endif
    }

    private func syncIndexOnAppear() {
        guard index == nil else { return }
        if let sel = selectionBinding.wrappedValue, let found = items.firstIndex(of: sel) {
            index = found
        } else if !items.isEmpty {
            index = 0
            selectionBinding.wrappedValue = items[0]
        }
    }

    /// Called when `items` changes under a stable view identity. Keeps the current selection
    /// if it's still present at the same index; otherwise re-resolves it (or falls back to
    /// the first item, or to nothing if `items` is now empty) rather than letting `selection`
    /// or `index` point past the end of the array.
    private func reconcile(after newItems: [Item]) {
        let currentlySelected = selectionBinding.wrappedValue
        if let idx = index, newItems.indices.contains(idx), let currentlySelected, newItems[idx] == currentlySelected {
            return
        }
        if let currentlySelected, let found = newItems.firstIndex(of: currentlySelected) {
            index = found
            return
        }
        index = newItems.isEmpty ? nil : 0
        selectionBinding.wrappedValue = newItems.first
    }
}

#if os(macOS)
/// macOS has no swipe to teach a pager affordance, so the arrows and dots stay visible
/// rather than appearing only on hover.
private struct MacMediaPager<Item: Hashable, ItemContent: View>: View {
    let items: [Item]
    @Binding var index: Int?
    let enableKeyboardNavigation: Bool
    let content: (Item) -> ItemContent

    var body: some View {
        if enableKeyboardNavigation && items.count > 1 {
            pagerStack
                .focusable()
                .onKeyPress(.leftArrow) { step(-1) ? .handled : .ignored }
                .onKeyPress(.rightArrow) { step(1) ? .handled : .ignored }
        } else {
            pagerStack
        }
    }

    private var pagerStack: some View {
        ZStack {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                        content(item)
                            .containerRelativeFrame(.horizontal)
                            .id(offset)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $index)
            .scrollDisabled(items.count <= 1)

            if items.count > 1 {
                HStack {
                    pagerArrow(systemName: "chevron.left", accessibilityLabel: "Previous image", enabled: (index ?? 0) > 0) { _ = step(-1) }
                    Spacer()
                    pagerArrow(systemName: "chevron.right", accessibilityLabel: "Next image", enabled: (index ?? 0) < items.count - 1) { _ = step(1) }
                }
                .padding(.horizontal, 12)
                .allowsHitTesting(true)

                VStack {
                    Spacer()
                    pageDots
                        .padding(.bottom, 10)
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// Moves the current page by `delta`. Returns whether the page actually moved, so key
    /// handlers can report `.ignored` at the ends and let the event propagate to the
    /// enclosing scroll view / list instead of swallowing it.
    @discardableResult
    private func step(_ delta: Int) -> Bool {
        guard let idx = index else {
            guard !items.isEmpty else { return false }
            index = 0
            return true
        }
        let next = idx + delta
        guard items.indices.contains(next) else { return false }
        withAnimation(Motion.pick) { index = next }
        return true
    }

    private func pagerArrow(systemName: String, accessibilityLabel: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                // Dimming the whole control also dimmed the scrim, which took the
                // disabled arrow to 1.6:1 over a bright image — and page 0 is the first
                // frame a macOS user sees, so half the affordance was invisible in it.
                // Only the glyph dims now; the scrim stays at full strength below.
                .foregroundColor(.white.opacity(enabled ? 1 : 0.55))
                .frame(width: 28, height: 28)
                // 0.7 opacity black over a worst-case bright (L≈0.9) image composites to an
                // effective background luminance of 0.9*(1-0.7) = 0.27; against a white
                // (L=1.0) glyph that's (1.0+0.05)/(0.27+0.05) ≈ 3.3:1, clearing the 3:1
                // WCAG non-text contrast minimum. The old 0.45 opacity only reached ~1.9:1.
                .background(Circle().fill(Color.black.opacity(0.7)))
                .overlay(Circle().stroke(Color.borderHairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(Motion.chrome, value: enabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                let isCurrent = i == (index ?? 0)
                Circle()
                    .fill(isCurrent ? Color.white : Color.white.opacity(0.55))
                    // A hairline stroke keeps inactive dots readable as a distinct state
                    // even when the fill alone would wash out over a bright photo.
                    .overlay(Circle().stroke(Color.white.opacity(isCurrent ? 0 : 0.9), lineWidth: 0.5))
                    .frame(width: isCurrent ? 6 : 5, height: isCurrent ? 6 : 5)
            }
        }
        .animation(Motion.pick, value: index)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.7)))
        // One element for the whole row, carrying the position as its label: a row of
        // circles read one at a time is noise, and macOS AX drops `value` on a group, so
        // the label is the only field that survives here.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Image \((index ?? 0) + 1) of \(items.count)")
    }
}
#endif
