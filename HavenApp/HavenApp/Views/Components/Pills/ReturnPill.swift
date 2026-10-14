import SwiftUI

/// Where the Vault item is on screen, for the return pill's arrow: the Vault
/// tab in the iPhone tab bar (`.bottom`), or the Vault row in the iPad
/// sidebar or the Mac window's sidebar (`.leading`). In global coordinates;
/// the iOS banner window and the app's window share them.
@MainActor
final class VaultAnchor: ObservableObject {
    static let shared = VaultAnchor()

    enum Edge { case bottom, leading }

    @Published private(set) var frame: CGRect?
    @Published private(set) var edge: Edge = .bottom

    fileprivate func set(_ frame: CGRect?, edge: Edge) {
        // Zero-size while the row is still being laid out.
        let frame = frame.flatMap { $0.isEmpty ? nil : $0 }
        if self.frame != frame { self.frame = frame }
        if self.edge != edge { self.edge = edge }
    }

    fileprivate func clear(edge: Edge) {
        // Only the reporter that set it clears it: the tab bar leaving as
        // the sidebar arrives must not wipe the sidebar's frame.
        if self.edge == edge { frame = nil }
    }
}

extension View {
    /// Marks this as the Vault item the return pill points at.
    func vaultAnchor(_ edge: VaultAnchor.Edge) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            VaultAnchor.shared.set($0, edge: edge)
        }
        .onDisappear { VaultAnchor.shared.clear(edge: edge) }
    }
}

/// The return pill (`ReturnPillManager`) over the whole screen: above the
/// tab bar with its arrow down at the Vault tab, or beside the sidebar with
/// its arrow at the Vault row. With no Vault item on screen it sits at the
/// bottom centre with no arrow.
/// - Parameter onFrame: where the pill is, in global coordinates, so the iOS
///   banner window takes taps on it and nowhere else. Nil while hidden.
struct ReturnPillLayer: View {
    var onFrame: (CGRect?) -> Void = { _ in }

    @ObservedObject private var manager = ReturnPillManager.shared
    @ObservedObject private var anchor = VaultAnchor.shared
    @ObservedObject private var row = FloatingButtonRow.shared
    @State private var pillSize: CGSize = .zero

    static let arrowLength: CGFloat = 8
    static let arrowWidth: CGFloat = 16
    /// Above the tab bar (and the mini player), and the gap a lifted
    /// floating button leaves above the pill.
    static let gap: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            if manager.isShowing {
                let place = placement(in: geo, origin: origin)
                pill(arrow: place.arrow, arrowAt: place.arrowAt)
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { pillSize = $0 }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame($0) }
                    .offset(x: place.origin.x, y: place.origin.y)
                    .opacity(pillSize == .zero ? 0 : 1)
                    .transition(.move(edge: place.arrow == .leading ? .leading : .bottom).combined(with: .opacity))
                    .onAppear { liftButtons(geo: geo) }
                    .onChange(of: pillSize) { _, _ in liftButtons(geo: geo) }
                    .onDisappear { onFrame(nil) }
            }
        }
        .ignoresSafeArea()
        .animation(Motion.bannerIn, value: manager.isShowing)
    }

    // MARK: - Placement

    private enum Arrow { case none, down, leading }

    private struct Placement {
        var origin: CGPoint
        var arrow: Arrow
        /// Along the pill's bottom edge (down) or left edge (leading).
        var arrowAt: CGFloat
    }

    /// Where the pill's bottom sits above the screen's bottom edge: over the
    /// tab bar and mini player on iPhone, 20 pt up where there's no tab bar.
    private func bottomInset(_ geo: GeometryProxy) -> CGFloat {
        geo.safeAreaInsets.bottom + (row.chromeHeight > 0 ? row.chromeHeight + Self.gap : 20)
    }

    private func placement(in geo: GeometryProxy, origin: CGPoint) -> Placement {
        let size = geo.size
        let w = pillSize.width, h = pillSize.height
        let margin = PillStyle.sideMargin
        if let frame = anchor.frame, anchor.edge == .leading {
            // Beside the sidebar, level with the Vault row, arrow pointing left.
            let x = frame.maxX - origin.x + 6
            let y = min(max(frame.midY - origin.y - h / 2, margin), size.height - h - margin)
            return Placement(origin: CGPoint(x: x, y: y), arrow: .leading,
                             arrowAt: frame.midY - origin.y - y)
        }
        // The arrow hangs below the pill, so its tip sits the gap above the bar.
        let y = size.height - bottomInset(geo) - Self.arrowLength - h
        guard let frame = anchor.frame else {
            return Placement(origin: CGPoint(x: (size.width - w) / 2, y: y), arrow: .none, arrowAt: 0)
        }
        // Over the Vault tab as far as the screen's edge allows; the arrow
        // stays on the tab.
        let target = frame.midX - origin.x
        let x = min(max(target - w / 2, margin), size.width - w - margin)
        return Placement(origin: CGPoint(x: x, y: y), arrow: .down, arrowAt: target - x)
    }

    /// Moves the screen's floating button (Post) up clear of the pill while
    /// it shows; `ReturnPillManager` settles it back as the pill goes.
    private func liftButtons(geo: GeometryProxy) {
        guard row.chromeHeight > 0, pillSize.height > 0 else { return }
        // The pill's top, above the bottom safe area, against the button's
        // usual bottom, which is measured from there too.
        let pillTop = bottomInset(geo) - geo.safeAreaInsets.bottom + Self.arrowLength + pillSize.height
        row.setLift(max(0, pillTop + Self.gap - row.buttonBottom))
    }

    // MARK: - Drawing

    private func pill(arrow: Arrow, arrowAt: CGFloat) -> some View {
        Button { manager.open() } label: {
            HStack(spacing: 8) {
                Image(systemName: VaultDashboard.symbol)
                    .font(PillSize.regular.iconFont)
                Text(manager.summary.text)
                    .font(PillSize.regular.font)
                    .lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(.vertical, PillSize.regular.vertical)
            .padding(.horizontal, PillSize.regular.horizontal)
            .background(Capsule().fill(PillTone.accent.color))
            .background(alignment: arrow == .leading ? .leading : .bottom) {
                pointer(arrow: arrow, at: arrowAt)
            }
            .compositingGroup()
            .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(ReturnPillButtonStyle())
        .accessibilityLabel("While you were away: \(manager.summary.spokenText)")
        .accessibilityHint("Opens the Vault")
    }

    @ViewBuilder
    private func pointer(arrow: Arrow, at: CGFloat) -> some View {
        let tone = PillTone.accent.color
        switch arrow {
        case .none:
            EmptyView()
        case .down:
            // The capsule's ends are round; keep the arrow on the straight part.
            let radius = pillSize.height / 2
            let along = min(max(at, radius), max(radius, pillSize.width - radius))
            ArrowShape(pointing: .down)
                .fill(tone)
                .frame(width: Self.arrowWidth, height: Self.arrowLength)
                .offset(x: along - pillSize.width / 2, y: Self.arrowLength)
        case .leading:
            let along = min(max(at, Self.arrowWidth / 2), max(Self.arrowWidth / 2, pillSize.height - Self.arrowWidth / 2))
            ArrowShape(pointing: .leading)
                .fill(tone)
                .frame(width: Self.arrowLength, height: Self.arrowWidth)
                .offset(x: -Self.arrowLength, y: along - pillSize.height / 2)
        }
    }
}

/// A small triangle, tip outward.
private struct ArrowShape: Shape {
    enum Pointing { case down, leading }
    let pointing: Pointing

    func path(in r: CGRect) -> Path {
        var p = Path()
        switch pointing {
        case .down:
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        case .leading:
            p.move(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        }
        p.closeSubpath()
        return p
    }
}

/// Darkens a little when pressed, rather than the default fade that lets
/// what's underneath show through.
private struct ReturnPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
