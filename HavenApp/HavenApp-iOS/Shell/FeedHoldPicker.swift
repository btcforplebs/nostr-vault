import SwiftUI
import UIKit

// MARK: - Feed Tab Hold Picker

/// Hold the Feed tab, slide up onto a feed, let go: that feed opens. Let go
/// without moving and the list stays up for a tap; let go anywhere else after
/// sliding and it closes. A plain tap is still the Feed tab.
///
/// The finger never leaves the tab's own drag gesture, so the list does not
/// need to take touches while dragging: the tab hit-tests the finger against
/// the rows' global frames itself.
@MainActor
final class FeedHoldPicker: ObservableObject {
    static let shared = FeedHoldPicker()

    @Published var isOpen = false
    @Published var hovered: FeedMode?
    /// The Feed tab's frame, global coordinates; the list rises from it.
    @Published var anchor: CGRect = .zero
    /// Each row's frame, global coordinates.
    var rowFrames: [FeedMode: CGRect] = [:]

    /// Closest to the finger first: the list grows upward from the tab, so
    /// Following (the usual feed) sits right above it.
    /// In the reader's feed order (Edit Feeds), hidden feeds left out.
    static var order: [FeedMode] { FeedMode.menuModes.reversed() }

    func mode(at point: CGPoint) -> FeedMode? {
        rowFrames.first { $0.value.insetBy(dx: -12, dy: 0).contains(point) }?.key
    }

    func open(from anchor: CGRect) {
        self.anchor = anchor
        hovered = nil
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { isOpen = true }
    }

    func close() {
        withAnimation(.easeOut(duration: 0.16)) { isOpen = false }
        hovered = nil
    }
}

struct FeedTabHoldItem: View {
    let selected: Bool
    @ObservedObject var feedService: FeedService
    let onTap: () -> Void

    @ObservedObject private var picker = FeedHoldPicker.shared
    @State private var frame: CGRect = .zero
    @State private var pressing = false
    @State private var moved = false
    @State private var holdTask: Task<Void, Never>?
    @State private var startedOpen = false

    private static let holdDelay: UInt64 = 300_000_000
    private static let slop: CGFloat = 10

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "person.2.wave.2")
                .font(.appSystem(size: 20, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.havenPurple : .white)
                .frame(height: 24)
            Text("Feed")
                .font(.appSystem(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.havenPurple : .white)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .scaleEffect(picker.isOpen ? 1.08 : (pressing ? 0.94 : 1))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressing)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: picker.isOpen)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged(changed)
                .onEnded(ended)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Feed")
        .accessibilityValue(feedService.feedMode.displayName)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Hold to pick a feed")
        .accessibilityAction { onTap() }
        .accessibilityActions {
            ForEach(FeedMode.menuModes, id: \.self) { mode in
                Button(mode.displayName) {
                    feedService.switchMode(mode)
                    if !selected { onTap() }
                }
            }
        }
    }

    private func changed(_ value: DragGesture.Value) {
        if !pressing {
            pressing = true
            moved = false
            // A touch that starts while the list is already up (tap mode)
            // picks or dismisses; it does not re-open it.
            startedOpen = picker.isOpen
            holdTask?.cancel()
            holdTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.holdDelay)
                guard !Task.isCancelled, pressing, !moved, !picker.isOpen else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                picker.open(from: frame)
            }
        }
        let distance = hypot(value.translation.width, value.translation.height)
        if distance > Self.slop { moved = true }
        guard picker.isOpen else {
            // Moved before the hold landed: just a tap that slid off.
            if moved { holdTask?.cancel() }
            return
        }
        let mode = picker.mode(at: value.location)
        if mode != picker.hovered {
            picker.hovered = mode
            if mode != nil { UISelectionFeedbackGenerator().selectionChanged() }
        }
    }

    private func ended(_ value: DragGesture.Value) {
        holdTask?.cancel()
        holdTask = nil
        defer { pressing = false }
        if picker.isOpen && !startedOpen {
            if let mode = picker.mode(at: value.location) {
                select(mode)
            } else if moved {
                picker.close()
            }
            // Held and let go in place: the list stays up for a tap.
            return
        }
        if picker.isOpen {
            // Tap on the Feed tab while the list is up: dismiss it.
            picker.close()
            return
        }
        if !moved && frame.contains(value.location) { onTap() }
    }

    private func select(_ mode: FeedMode) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        picker.close()
        if mode != feedService.feedMode { feedService.switchMode(mode) }
        if !selected { onTap() }
    }
}

/// The list itself, drawn over the whole screen so it can rise above the bar.
struct FeedHoldPickerOverlay: View {
    @ObservedObject var feedService: FeedService
    let onSelect: (FeedMode) -> Void
    @ObservedObject private var picker = FeedHoldPicker.shared

    var body: some View {
        GeometryReader { geo in
            let space = geo.frame(in: .global)
            ZStack(alignment: .bottomLeading) {
                if picker.isOpen {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { picker.close() }
                        .transition(.opacity)

                    list
                        .padding(.leading, max(12, picker.anchor.minX - space.minX))
                        .padding(.bottom, max(12, space.maxY - picker.anchor.minY + 10))
                        .transition(
                            .scale(scale: 0.6, anchor: .bottomLeading)
                                .combined(with: .opacity)
                        )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(picker.isOpen)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(FeedHoldPicker.order, id: \.self) { mode in
                row(mode)
            }
        }
        .padding(6)
        .fixedSize()
        .applyGlassRect(cornerRadius: 22)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    private func row(_ mode: FeedMode) -> some View {
        let current = feedService.feedMode == mode
        let hovered = picker.hovered == mode
        return Button {
            picker.close()
            onSelect(mode)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: mode.symbolName)
                    .font(.appSystem(size: 16, weight: .semibold))
                    .frame(width: 24)
                Text(mode.displayName)
                    .font(.appSystem(size: 16, weight: current ? .bold : .medium))
                Spacer(minLength: 16)
                if current {
                    Image(systemName: "checkmark")
                        .font(.appSystem(size: 13, weight: .bold))
                }
            }
            .foregroundStyle(hovered ? Color.white : (current ? Color.havenPurple : Color.primary))
            .padding(.horizontal, 14)
            .frame(width: 210, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(hovered ? Color.havenPurple : Color.clear)
            )
            .scaleEffect(hovered ? 1.04 : 1, anchor: .leading)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: hovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { picker.rowFrames[mode] = $0 }
    }
}
