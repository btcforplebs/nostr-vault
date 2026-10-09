import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Quick reactions for a note, like iMessage tapbacks. Hold the reaction
/// button and a bar of emoji rises above it: slide onto one and let go to send
/// it, or let go anywhere else and the bar stays up for a tap.
///
/// On iOS the bar is drawn by `ReactionTapbackLayer` in the banner window,
/// above every sheet, so it is never clipped by a row or covered by a note.
/// The row that opened it keeps the touch and only reports where the finger
/// is. macOS shows the same bar in a popover instead.
@MainActor
final class ReactionTapback: ObservableObject {
    static let shared = ReactionTapback()

    struct Session {
        let id = UUID()
        /// The note whose button opened the bar.
        let noteId: String
        /// The reaction button, in window space.
        let anchor: CGRect
        let options: [String]
        /// The account's current reaction as displayed, if there is one.
        let current: String?
        let onPick: (String) -> Void
        let onMore: () -> Void
    }

    @Published private(set) var session: Session?
    /// The slot under the finger. `options.count` is the "more" slot.
    @Published private(set) var highlighted: Int?
    /// The finger that opened the bar is still down.
    @Published private(set) var isTracking = false

    /// Where the bar is drawn, in window space. Set by the layer.
    var barFrame: CGRect = .zero
    /// Told when the bar starts and stops waiting for a tap, so the window it
    /// is drawn in can take touches (and a tap outside can close it).
    var onModalChange: ((Bool) -> Void)?

    static let slot: CGFloat = 44
    static let inset: CGFloat = 6

    /// The bar's emoji: the account's default reaction first if it is not
    /// already one of them.
    static func options(defaultContent: String) -> [String] {
        var list = ["❤️", "🤙", "🔥", "😂", "😮", "😢"]
        let mine = reactionDisplayEmoji(defaultContent)
        if !list.contains(mine) {
            list.removeLast()
            list.insert(mine, at: 0)
        }
        return list
    }

    static func barSize(optionCount: Int) -> CGSize {
        CGSize(width: inset * 2 + slot * CGFloat(optionCount + 1), height: inset * 2 + slot)
    }

    func begin(noteId: String, anchor: CGRect, current: String?, defaultContent: String,
               onPick: @escaping (String) -> Void, onMore: @escaping () -> Void) {
        close()
        session = Session(noteId: noteId, anchor: anchor, options: Self.options(defaultContent: defaultContent),
                          current: current, onPick: onPick, onMore: onMore)
        highlighted = nil
        barFrame = .zero
        isTracking = true
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    /// The finger moved to `point`, in window space.
    func track(_ point: CGPoint) {
        guard isTracking, let session, barFrame != .zero else { return }
        // Generous on the far side, where a thumb sliding along the bar
        // drifts; tight on the button's side, so a finger resting on the
        // button picks nothing and letting go leaves the bar up.
        let barAbove = barFrame.midY < session.anchor.midY
        var zone = barFrame.insetBy(dx: -8, dy: 0)
        zone.origin.y -= barAbove ? 36 : 6
        zone.size.height += 42
        var index: Int?
        if zone.contains(point), !session.anchor.contains(point) {
            let x = point.x - barFrame.minX - Self.inset
            index = min(max(Int(x / Self.slot), 0), session.options.count)
        }
        guard index != highlighted else { return }
        highlighted = index
        #if os(iOS)
        if index != nil { UISelectionFeedbackGenerator().selectionChanged() }
        #endif
    }

    /// The finger lifted: send what it was on, or wait for a tap.
    func release() {
        guard isTracking else { return }
        isTracking = false
        if let highlighted {
            choose(highlighted)
        } else {
            onModalChange?(true)
        }
    }

    func choose(_ index: Int) {
        guard let session else { return }
        close()
        if index < session.options.count {
            session.onPick(session.options[index])
        } else {
            session.onMore()
        }
    }

    /// Closes the bar if the row for `noteId` opened it.
    func close(for noteId: String) {
        if session?.noteId == noteId { close() }
    }

    func close() {
        guard session != nil else { return }
        session = nil
        highlighted = nil
        isTracking = false
        barFrame = .zero
        onModalChange?(false)
    }
}

/// The row of emoji itself, shared by the iOS layer and the macOS popover.
struct ReactionTapbackBar: View {
    let options: [String]
    let current: String?
    let highlighted: Int?
    let onChoose: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, emoji in
                Button { onChoose(index) } label: {
                    Text(emoji)
                        .font(.system(size: 26))
                        .frame(width: ReactionTapback.slot, height: ReactionTapback.slot)
                        .background {
                            if emoji == current {
                                Circle().fill(Color.accentColor.opacity(0.3))
                            }
                        }
                        .scaleEffect(highlighted == index ? 1.45 : 1)
                        .offset(y: highlighted == index ? -10 : 0)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(emoji == current ? "\(emoji), your reaction" : emoji)
            }
            Button { onChoose(options.count) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .frame(width: ReactionTapback.slot, height: ReactionTapback.slot)
                    .scaleEffect(highlighted == options.count ? 1.3 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More reactions")
        }
        .padding(ReactionTapback.inset)
        .animation(Motion.pick, value: highlighted)
        .background(
            Capsule()
                .fill(Color(white: 0.17))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        )
    }
}

#if os(iOS)
/// Draws the open tapback bar over the whole app. Lives in the banner window.
struct ReactionTapbackLayer: View {
    @ObservedObject private var tapback = ReactionTapback.shared
    @State private var shown = false

    var body: some View {
        GeometryReader { geo in
            if let session = tapback.session {
                ZStack(alignment: .topLeading) {
                    if !tapback.isTracking {
                        // Waiting for a tap: anywhere outside the bar closes it.
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture { tapback.close() }
                            .accessibilityHidden(true)
                    }
                    let size = ReactionTapback.barSize(optionCount: session.options.count)
                    let frame = Self.frame(for: size, anchor: session.anchor, in: geo)
                    ReactionTapbackBar(options: session.options, current: session.current,
                                       highlighted: tapback.highlighted) { tapback.choose($0) }
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(shown ? 1 : 0.5, anchor: frame.minY < session.anchor.minY ? .bottom : .top)
                        .opacity(shown ? 1 : 0)
                        .position(x: frame.midX, y: frame.midY)
                        .onAppear {
                            tapback.barFrame = frame
                            withAnimation(Motion.pop) { shown = true }
                        }
                        .onDisappear { shown = false }
                        .accessibilityAddTraits(.isModal)
                        // A new session is a new bar: appear (and measure) again.
                        .id(session.id)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
    }

    /// Centred over the button and kept on screen; below it when the status
    /// and navigation bars leave no room above.
    private static func frame(for size: CGSize, anchor: CGRect, in geo: GeometryProxy) -> CGRect {
        let margin: CGFloat = 8
        let x = min(max(anchor.midX - size.width / 2, margin), geo.size.width - size.width - margin)
        let above = anchor.minY - 12 - size.height
        let y = above >= 100 ? above : anchor.maxY + 12
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
#endif
