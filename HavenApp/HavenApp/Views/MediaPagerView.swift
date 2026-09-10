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

    private let externalSelection: Binding<Item?>?
    @State private var localSelection: Item?

    init(items: [Item], selection: Binding<Item?>? = nil, @ViewBuilder content: @escaping (Item) -> ItemContent) {
        self.items = items
        self.externalSelection = selection
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

    var body: some View {
        #if os(iOS)
        TabView(selection: selectionBinding) {
            ForEach(items, id: \.self) { item in
                content(item).tag(item as Item?)
            }
        }
        // Dots hidden so the viewer stays clean; callers show their own position UI where needed.
        .tabViewStyle(.page(indexDisplayMode: .never))
        #else
        MacMediaPager(items: items, selection: selectionBinding, content: content)
        #endif
    }
}

#if os(macOS)
/// macOS has no swipe to teach a pager affordance, so the arrows and dots stay visible
/// rather than appearing only on hover.
private struct MacMediaPager<Item: Hashable, ItemContent: View>: View {
    let items: [Item]
    @Binding var selection: Item?
    let content: (Item) -> ItemContent

    private var currentIndex: Int? {
        guard let selection else { return nil }
        return items.firstIndex(of: selection)
    }

    var body: some View {
        ZStack {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(items, id: \.self) { item in
                        content(item)
                            .containerRelativeFrame(.horizontal)
                            .id(item)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selection)
            .scrollDisabled(items.count <= 1)

            if items.count > 1 {
                HStack {
                    pagerArrow(systemName: "chevron.left", enabled: (currentIndex ?? 0) > 0) { step(-1) }
                    Spacer()
                    pagerArrow(systemName: "chevron.right", enabled: (currentIndex ?? 0) < items.count - 1) { step(1) }
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
        .focusable()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onAppear {
            if selection == nil { selection = items.first }
        }
    }

    private func step(_ delta: Int) {
        guard let idx = currentIndex else {
            selection = items.first
            return
        }
        let next = idx + delta
        guard items.indices.contains(next) else { return }
        withAnimation(Motion.pick) { selection = items[next] }
    }

    private func pagerArrow(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.black.opacity(0.45)))
                .overlay(Circle().stroke(Color.borderHairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .animation(Motion.chrome, value: enabled)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                let isCurrent = i == (currentIndex ?? 0)
                Circle()
                    .fill(isCurrent ? Color.white : Color.white.opacity(0.35))
                    .frame(width: isCurrent ? 6 : 5, height: isCurrent ? 6 : 5)
            }
        }
        .animation(Motion.pick, value: currentIndex)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.45)))
    }
}
#endif
