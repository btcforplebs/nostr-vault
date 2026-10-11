import SwiftUI

// MARK: - Lesson pictures

/// The small diagram under each import-tour lesson (mockup's pictures,
/// drawn with SF Symbols). Decorative: the text says the same thing.
struct ImportTourArt: View {
    let lesson: Int

    private let accent = WizardColors.accentPrimary
    private let muted = WizardColors.textMuted

    var body: some View {
        Group {
            switch lesson {
            case 0: why
            case 1: pocket
            case 2: publicVsYours
            case 3: macAddress
            default: webOfTrust
            }
        }
        .frame(height: 110)
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String, _ color: Color, size: CGFloat = 30) -> some View {
        Image(systemName: name).font(.system(size: size, weight: .regular)).foregroundColor(color)
    }

    private func caption(_ text: String, _ color: Color = WizardColors.textSecondary) -> some View {
        Text(text).font(.appSystem(size: 10, weight: .medium)).foregroundColor(color)
    }

    /// A relay, a deleted relay, and the copy on your phone.
    private var why: some View {
        HStack(spacing: 18) {
            VStack(spacing: 10) {
                VStack(spacing: 2) { symbol("server.rack", WizardColors.textSecondary, size: 22); caption("relay") }
                VStack(spacing: 2) {
                    symbol("server.rack", muted, size: 22)
                        .overlay(symbol("xmark", WizardColors.error, size: 16))
                    caption("deleted", muted)
                }
            }
            symbol("arrow.right", accent, size: 20)
            VStack(spacing: 2) { symbol("iphone", accent, size: 44); caption("your copy", WizardColors.textPrimary) }
        }
    }

    /// Your relay sends out; nothing reaches in.
    private var pocket: some View {
        HStack(spacing: 14) {
            VStack(spacing: 2) {
                symbol("network", muted, size: 22)
                caption("network", muted)
            }
            symbol("nosign", WizardColors.error, size: 18)
            VStack(spacing: 2) { symbol("iphone.radiowaves.left.and.right", accent, size: 44); caption("your relay", WizardColors.textPrimary) }
            VStack(spacing: 6) {
                symbol("arrow.up.right", accent, size: 16)
                symbol("arrow.right", accent, size: 16)
                symbol("arrow.down.right", accent, size: 16)
            }
        }
    }

    /// Yours sends a post out to the shared public relays.
    private var publicVsYours: some View {
        HStack(spacing: 18) {
            VStack(spacing: 2) { symbol("iphone", accent, size: 44); caption("yours", WizardColors.textPrimary) }
            symbol("arrow.right", accent, size: 20)
            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 4) { symbol("server.rack", WizardColors.textSecondary, size: 16); caption("public") }
                }
            }
        }
    }

    /// A Mac with your own address; your phone syncs from it.
    private var macAddress: some View {
        HStack(spacing: 16) {
            symbol("iphone", WizardColors.textSecondary, size: 34)
            symbol("arrow.left.arrow.right", muted, size: 16)
            VStack(spacing: 4) {
                symbol("desktopcomputer", accent, size: 46)
                caption("relay.you.com", WizardColors.textPrimary)
                caption("up 24/7")
            }
        }
    }

    /// You, your follows, and the people they follow.
    private var webOfTrust: some View {
        let center = CGPoint(x: 60, y: 50)
        let points = (0..<6).map { k -> CGPoint in
            let angle = Double(k) * .pi / 3
            return CGPoint(x: center.x + 44 * cos(angle), y: center.y + 38 * sin(angle))
        }
        return ZStack {
            Path { p in
                for point in points {
                    p.move(to: center)
                    p.addLine(to: point)
                }
            }
            .stroke(accent.opacity(0.5), lineWidth: 1)
            ForEach(points.indices, id: \.self) { k in
                symbol("person.circle.fill", WizardColors.textSecondary, size: 20)
                    .position(points[k])
            }
            symbol("person.circle.fill", accent, size: 30)
                .position(center)
        }
        .frame(width: 120, height: 100)
    }
}
