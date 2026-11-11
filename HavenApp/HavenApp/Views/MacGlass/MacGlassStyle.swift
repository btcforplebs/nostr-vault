import SwiftUI

#if os(macOS)

// The Mac glass look (RESEARCH spec §0.1): real Liquid Glass on macOS 26,
// a system material before it. Glass is for chrome (the panel's status strip,
// the floating sidebar, toolbar groups), never for content: tiles and lists
// get a plain fill so the chrome reads as the layer above them.
//
// Same pattern as `applyGlassRect` in PlatformCompat.swift, but shape-generic
// and without the OLED knob, which the Mac does not offer.
extension View {
    /// Glass on macOS 26+, `fallback` material before it.
    @ViewBuilder
    func macGlass<S: Shape>(in shape: S, tint: Color? = nil, fallback: Material = .ultraThinMaterial) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            self
                .background(fallback, in: shape)
                .background((tint ?? .clear).opacity(0.18), in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 0.5))
        }
    }

    /// The plain, non-glass fill content tiles sit on.
    func macContentTile(cornerRadius: CGFloat = 12) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}

/// A glass push button on macOS 26, a bordered one before it.
struct MacGlassButtonStyle: ViewModifier {
    var prominent = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent).tint(.havenPurple)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent).tint(.havenPurple)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }
}

extension View {
    func macGlassButton(prominent: Bool = false) -> some View {
        modifier(MacGlassButtonStyle(prominent: prominent))
    }
}

/// Groups sibling glass shapes so macOS 26 can blend them; a plain stack before.
struct MacGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// The arch mark, lit by the vault's state (inventory #1): it glows while
/// running, dims while stopped, and pulses while booting or importing.
struct MacVaultArchMark: View {
    enum Glow { case running, busy, stopped }

    let glow: Glow
    var size: CGFloat = 26

    @State private var pulsing = false

    var body: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(glow == .stopped ? Color.secondary : Color.havenPurple)
            .shadow(color: glow == .stopped ? .clear : Color.havenPurple.opacity(0.75), radius: glow == .stopped ? 0 : 8)
            .opacity(glow == .busy && pulsing ? 0.45 : 1)
            .animation(glow == .busy ? Motion.ambientPulse : Motion.fade, value: pulsing)
            .onAppear { pulsing = glow == .busy && Motion.ambientPulse != nil }
            .onChange(of: glow) { _, new in pulsing = new == .busy && Motion.ambientPulse != nil }
            .accessibilityHidden(true)
    }
}

/// A soft dark backdrop with an orange arch glow, so glass above it has
/// something to refract instead of a flat colour.
struct MacGlassBackdrop: View {
    var body: some View {
        ZStack {
            Color.platformWindowBackground
            RadialGradient(
                colors: [Color.havenPurple.opacity(0.22), .clear],
                center: .init(x: 0.12, y: 0.0),
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [Color.havenPurple.opacity(0.08), .clear],
                center: .init(x: 0.9, y: 1.0),
                startRadius: 0,
                endRadius: 600
            )
        }
        .ignoresSafeArea()
    }
}

#endif
