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
                    if let anchor {
                        highlight(anchor)
                    }
                    card(id: id, step: step)
                        .frame(width: min(340, proxy.size.width - 32))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onCardFrame($0) }
                        .position(cardCenter(anchor: anchor, in: proxy.size))
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

    /// Below the anchor when it's in the top half of the screen, above it
    /// otherwise, kept on screen. With no anchor, low and centred.
    private func cardCenter(anchor: CGRect?, in size: CGSize) -> CGPoint {
        let estimatedHeight: CGFloat = 170
        guard let anchor else {
            return CGPoint(x: size.width / 2, y: size.height - estimatedHeight / 2 - 120)
        }
        let halfWidth = min(340, size.width - 32) / 2
        let x = min(max(anchor.midX, halfWidth + 16), size.width - halfWidth - 16)
        let y = anchor.midY < size.height / 2
            ? anchor.maxY + 16 + estimatedHeight / 2
            : anchor.minY - 16 - estimatedHeight / 2
        return CGPoint(x: x, y: y)
    }

    private func card(id: TutorialID, step: TutorialStep) -> some View {
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
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(white: 0.12))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.havenPurple.opacity(0.6), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}
