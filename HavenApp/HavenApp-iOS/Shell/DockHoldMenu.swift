import SwiftUI
import UIKit

// MARK: - Dock Hold Menu

/// One row in a dock tab's hold menu.
struct DockHoldEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    var isCurrent = false
    var hasNews = false
}

/// Press and hold a dock tab, slide onto a row, let go: that row is picked.
/// Let go anywhere else (the tab itself included) and the menu closes with
/// nothing picked. A plain tap is still the tab's own tap.
///
/// The finger never leaves the tab's own drag gesture, so the menu does not
/// take touches while dragging: the tab hit-tests the finger against the
/// rows' global frames itself.
///
/// The numbers live here so Android can match them.
@MainActor
final class DockHoldMenu: ObservableObject {
    static let shared = DockHoldMenu()

    /// Hold before the menu opens. The account switcher's system menu takes
    /// about 0.5 s; this is meant to feel quicker than that but still longer
    /// than a tap (most taps lift within ~0.1 s).
    static let holdDelay: Double = 0.18
    /// Movement before the hold lands that turns it back into a plain touch.
    static let slop: CGFloat = 10
    /// Extra width either side of a row that still counts as on it.
    static let rowSideSlop: CGFloat = 28

    @Published private(set) var isOpen = false
    @Published var hovered: String?
    /// The tab's frame, global coordinates; the menu rises from it.
    @Published private(set) var anchor: CGRect = .zero
    /// Rows in menu order. The overlay draws them bottom-up, so the first one
    /// sits right above the finger.
    @Published private(set) var entries: [DockHoldEntry] = []
    /// Each row's frame, global coordinates.
    var rowFrames: [String: CGRect] = [:]
    private var onPick: ((String) -> Void)?

    func entry(at point: CGPoint) -> String? {
        rowFrames.first {
            $0.value.insetBy(dx: -Self.rowSideSlop, dy: -1).contains(point)
        }?.key
    }

    func open(from anchor: CGRect, entries: [DockHoldEntry], onPick: @escaping (String) -> Void) {
        self.anchor = anchor
        self.entries = entries
        self.onPick = onPick
        rowFrames = [:]
        hovered = nil
        withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) { isOpen = true }
    }

    func pick(_ id: String) {
        let action = onPick
        close()
        action?(id)
    }

    func close() {
        withAnimation(.easeOut(duration: 0.14)) { isOpen = false }
        hovered = nil
        onPick = nil
    }
}

// MARK: - Hold Button

/// A dock tab with a hold menu. `entries` is read when the hold lands, so it
/// shows the state of that moment.
struct DockHoldButton<Label: View>: View {
    let onTap: () -> Void
    let entries: () -> [DockHoldEntry]
    let onPick: (String) -> Void
    @ViewBuilder let label: () -> Label

    @ObservedObject private var menu = DockHoldMenu.shared
    @State private var frame: CGRect = .zero
    @State private var pressing = false
    @State private var moved = false
    @State private var openedHere = false
    @State private var holdTask: Task<Void, Never>?
    @State private var openHaptic: UIImpactFeedbackGenerator?
    @State private var tickHaptic: UISelectionFeedbackGenerator?

    var body: some View {
        label()
            .contentShape(Rectangle())
            .scaleEffect(openedHere && menu.isOpen ? 1.08 : (pressing ? 0.94 : 1))
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pressing)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: menu.isOpen)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged(changed)
                    .onEnded(ended)
            )
    }

    private func changed(_ value: DragGesture.Value) {
        if !pressing {
            pressing = true
            moved = false
            openedHere = false
            // Warm the Taptic Engine now, so the open buzz lands on the frame
            // the menu appears instead of a beat later.
            let open = UIImpactFeedbackGenerator(style: .light)
            open.prepare()
            openHaptic = open
            let tick = UISelectionFeedbackGenerator()
            tick.prepare()
            tickHaptic = tick
            holdTask?.cancel()
            holdTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(DockHoldMenu.holdDelay * 1_000_000_000))
                guard !Task.isCancelled, pressing, !moved else { return }
                openedHere = true
                openHaptic?.impactOccurred()
                tickHaptic?.prepare()
                menu.open(from: frame, entries: entries(), onPick: onPick)
            }
        }
        if hypot(value.translation.width, value.translation.height) > DockHoldMenu.slop { moved = true }
        guard openedHere, menu.isOpen else {
            // Slid off before the hold landed: a tap that changed its mind.
            if moved { holdTask?.cancel() }
            return
        }
        let id = menu.entry(at: value.location)
        if id != menu.hovered {
            menu.hovered = id
            if id != nil {
                tickHaptic?.selectionChanged()
                tickHaptic?.prepare()
            }
        }
    }

    private func ended(_ value: DragGesture.Value) {
        holdTask?.cancel()
        holdTask = nil
        defer {
            pressing = false
            openedHere = false
            openHaptic = nil
            tickHaptic = nil
        }
        if openedHere {
            guard menu.isOpen else { return }
            if let id = menu.entry(at: value.location) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                menu.pick(id)
            } else {
                menu.close()
            }
            return
        }
        if !moved && frame.contains(value.location) { onTap() }
    }
}

// MARK: - Overlay

/// The open menu, drawn over the whole screen so it can rise above the bar.
/// It lines up with the side of the screen its tab is on.
struct DockHoldMenuOverlay: View {
    @ObservedObject private var menu = DockHoldMenu.shared

    var body: some View {
        GeometryReader { geo in
            let space = geo.frame(in: .global)
            let trailing = menu.anchor.midX > space.midX
            let alignment: Alignment = trailing ? .bottomTrailing : .bottomLeading
            ZStack(alignment: alignment) {
                if menu.isOpen {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { menu.close() }
                        .transition(.opacity)

                    list
                        .padding(.leading, trailing ? 12 : max(12, menu.anchor.minX - space.minX))
                        .padding(.trailing, trailing ? max(12, space.maxX - menu.anchor.maxX) : 12)
                        .padding(.bottom, max(12, space.maxY - menu.anchor.minY + 10))
                        .transition(
                            .scale(scale: 0.6, anchor: trailing ? .bottomTrailing : .bottomLeading)
                                .combined(with: .opacity)
                        )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: alignment)
        }
        .ignoresSafeArea()
        .allowsHitTesting(menu.isOpen)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(menu.entries.reversed()) { entry in
                row(entry)
            }
        }
        .padding(6)
        .fixedSize()
        .applyGlassRect(cornerRadius: 22)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    private func row(_ entry: DockHoldEntry) -> some View {
        let hovered = menu.hovered == entry.id
        return Button {
            menu.pick(entry.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.symbol)
                    .font(.appSystem(size: 16, weight: .semibold))
                    .frame(width: 24)
                    .overlay(alignment: .topTrailing) {
                        NewsDot(isShown: entry.hasNews, size: 8)
                            .offset(x: 2, y: -2)
                    }
                Text(entry.title)
                    .font(.appSystem(size: 16, weight: entry.isCurrent ? .bold : .medium))
                Spacer(minLength: 16)
                if entry.isCurrent {
                    Image(systemName: "checkmark")
                        .font(.appSystem(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(hovered ? Color.white : (entry.isCurrent ? Color.havenPurple : Color.primary))
            .padding(.horizontal, 14)
            .frame(width: 210, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(hovered ? Color.havenPurple : Color.clear)
            )
            .scaleEffect(hovered ? 1.04 : 1, anchor: .center)
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: hovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(entry.hasNews ? "New activity" : "")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { menu.rowFrames[entry.id] = $0 }
    }
}
