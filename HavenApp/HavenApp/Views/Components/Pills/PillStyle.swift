import SwiftUI

/// What a pill's colour says. One meaning each; see `docs/pills.md`.
enum PillTone {
    /// Level-1 errors only.
    case error
    /// Level-1 warnings only.
    case warning
    /// A result that went through.
    case success
    /// In progress, on, and the app's own pills.
    case accent
    /// Off, hidden, undone, pending.
    case neutral

    var color: Color {
        switch self {
        case .error:   return Color.red.opacity(0.85)
        case .warning: return Color.orange.opacity(0.85)
        case .success: return Color(red: 0.2, green: 0.8, blue: 0.6)
        case .accent:  return .havenPurple
        case .neutral: return Color(white: 0.35)
        }
    }
}

/// Regular: anything you can tap, and every error and result pill.
/// Small: information only.
enum PillSize {
    case regular
    case small

    var font: Font { self == .regular ? .appSystem(size: 13, weight: .bold) : .appSystem(size: 12, weight: .semibold) }
    var iconFont: Font { self == .regular ? .appSystem(size: 12, weight: .bold) : .appSystem(size: 11, weight: .bold) }
    var vertical: CGFloat { self == .regular ? 10 : 6 }
    var horizontal: CGFloat { self == .regular ? 20 : 14 }
}

enum PillStyle {
    /// Between pills in the lane, and above the first.
    static let gap: CGFloat = 6
    /// The lane never runs closer than this to the screen's sides.
    static let sideMargin: CGFloat = 16
}

extension View {
    /// The lane's capsule: solid `tone`, white text, the shared shadow and
    /// padding for `size`. Pass `vertical` to override the padding when a
    /// 44 pt button inside sets the height.
    func pillCapsule(_ tone: PillTone, size: PillSize = .regular, vertical: CGFloat? = nil) -> some View {
        font(size.font)
            .foregroundColor(.white)
            .padding(.vertical, vertical ?? size.vertical)
            .padding(.horizontal, size.horizontal)
            .background(
                Capsule()
                    .fill(tone.color)
                    .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
            )
            .padding(.horizontal, PillStyle.sideMargin)
    }
}

/// The text button inside a regular pill (Undo, Edit): 13 pt bold,
/// underlined, at least 44 pt tall to tap.
struct PillButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .font(.appSystem(size: 13, weight: .bold))
            .underline()
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}
