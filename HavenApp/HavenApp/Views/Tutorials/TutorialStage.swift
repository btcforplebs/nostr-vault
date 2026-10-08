import SwiftUI

/// Draws the active tutorial's card, pointing at its anchor. It sits over
/// the live app and never dims or blocks it: only the card takes touches.
///
/// On iPhone and iPad it lives in the banner window (SceneDelegate), so a
/// sheet or the navigation bar can't cover it. `onCardFrame` reports the
/// card's frame so that window knows which touches are the card's.
struct TutorialStage: View {
    var onCardFrame: (CGRect?) -> Void = { _ in }

    @ObservedObject private var center = TutorialCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                // A card that points at something waits until that thing is
                // on screen: replayed from Settings, the feed is still
                // sliding back into view.
                if let id = center.active, let step = center.currentStep,
                   step.anchor == nil || step.anchor.flatMap({ center.anchors[$0] }) != nil {
                    let anchor = step.anchor
                        .flatMap { center.anchors[$0] }
                        .map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
                    let placement = TutorialCardPlacement(anchor: anchor, in: proxy.size)
                    if let anchor {
                        highlight(anchor)
                    }
                    card(id: id, step: step, placement: placement)
                        .frame(width: placement.width)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onCardFrame($0) }
                        .padding(placement.edge)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: placement.alignment)
                        .transition(.opacity)
                        .id("\(id.rawValue).\(center.stepIndex)")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: center.stepIndex)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: center.active)
        .onChange(of: isShowingCard) { _, showing in
            if !showing { onCardFrame(nil) }
        }
    }

    private var isShowingCard: Bool {
        guard let step = center.currentStep else { return false }
        return step.anchor == nil || step.anchor.flatMap({ center.anchors[$0] }) != nil
    }

    private var account: String { NostrService.shared.activeHexPubkey }

    /// A ring around what the card is about. Purely visual: touches go
    /// straight through to the button underneath.
    private func highlight(_ rect: CGRect) -> some View {
        RoundedRectangle(cornerRadius: min(rect.height / 2 + 6, 22), style: .continuous)
            .stroke(Color.havenPurple, lineWidth: 3)
            .shadow(color: Color.havenPurple.opacity(0.7), radius: 8)
            .frame(width: rect.width + 12, height: rect.height + 12)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func card(id: TutorialID, step: TutorialStep, placement: TutorialCardPlacement) -> some View {
        let count = id.steps.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(center.stepIndex + 1) of \(count)")
                    .font(.appCaption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Skip") { center.skip(id, account: account) }
                    .font(.appCaption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .accessibilityHint(Text("Closes this tutorial. Replay it from Settings, Tutorials."))
            }
            Text(step.title)
                .font(.appHeadline)
                .foregroundColor(.white)
            Text(step.body)
                .font(.appSubheadline)
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if center.stepIndex > 0 {
                    Button("Back") { center.back() }
                        .foregroundColor(.white.opacity(0.85))
                }
                Spacer()
                Button(center.isLastStep ? "Done" : "Next") { center.next(account: account) }
                    .font(.appBody.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.havenPurple))
                    .foregroundColor(.white)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background {
            let shape = TutorialCardShape(tail: placement.tail)
            shape
                .fill(Color(white: 0.12))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                .overlay(shape.stroke(Color.havenPurple.opacity(0.6), lineWidth: 1))
        }
        .accessibilityElement(children: .contain)
    }
}

/// Where a card sits and where its tail points. Below the anchor when the
/// anchor is in the top half of the screen, above it otherwise, kept on
/// screen; the tail sits on the edge facing the anchor, under its middle.
/// With no anchor: low and centred, no tail. Edges are set rather than a
/// centre, so the card's real height never matters and it can't cover what
/// it points at.
struct TutorialCardPlacement {
    enum TailEdge { case top, bottom }
    struct Tail: Equatable {
        let edge: TailEdge
        /// The tip's x, from the card's leading edge.
        let x: CGFloat
    }

    static let maxWidth: CGFloat = 340
    static let margin: CGFloat = 16
    /// The ring's outset plus a little air, so the tip stops just short of it.
    static let ringGap: CGFloat = 10
    static let tailHeight: CGFloat = 10
    static let tailHalfWidth: CGFloat = 11
    static let cornerRadius: CGFloat = 18

    let width: CGFloat
    let minX: CGFloat
    let alignment: Alignment
    let edge: EdgeInsets
    let tail: Tail?

    init(anchor: CGRect?, in size: CGSize) {
        width = min(Self.maxWidth, size.width - 2 * Self.margin)
        guard let anchor else {
            minX = (size.width - width) / 2
            alignment = .bottomLeading
            edge = EdgeInsets(top: 0, leading: minX, bottom: 120, trailing: 0)
            tail = nil
            return
        }
        let center = min(max(anchor.midX, width / 2 + Self.margin), size.width - width / 2 - Self.margin)
        minX = center - width / 2
        let inset = Self.cornerRadius + Self.tailHalfWidth
        let tipX = min(max(anchor.midX - minX, inset), width - inset)
        let gap = Self.ringGap + Self.tailHeight
        if anchor.midY < size.height / 2 {
            alignment = .topLeading
            edge = EdgeInsets(top: anchor.maxY + gap, leading: minX, bottom: 0, trailing: 0)
            tail = Tail(edge: .top, x: tipX)
        } else {
            alignment = .bottomLeading
            edge = EdgeInsets(top: 0, leading: minX, bottom: size.height - anchor.minY + gap, trailing: 0)
            tail = Tail(edge: .bottom, x: tipX)
        }
    }
}

/// The card's rounded body with a speech-bubble tail, as one outline so the
/// border runs round the tail too.
struct TutorialCardShape: Shape {
    let tail: TutorialCardPlacement.Tail?

    func path(in rect: CGRect) -> Path {
        let r = min(TutorialCardPlacement.cornerRadius, rect.height / 2)
        let h = TutorialCardPlacement.tailHeight
        let w = TutorialCardPlacement.tailHalfWidth
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        if let tail, tail.edge == .top {
            p.addLine(to: CGPoint(x: rect.minX + tail.x - w, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + tail.x, y: rect.minY - h))
            p.addLine(to: CGPoint(x: rect.minX + tail.x + w, y: rect.minY))
        }
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        if let tail, tail.edge == .bottom {
            p.addLine(to: CGPoint(x: rect.minX + tail.x + w, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX + tail.x, y: rect.maxY + h))
            p.addLine(to: CGPoint(x: rect.minX + tail.x - w, y: rect.maxY))
        }
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: r)
        p.closeSubpath()
        return p
    }
}
