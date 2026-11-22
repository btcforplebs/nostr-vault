import SwiftUI

/// The three key steps' header (setup screens r3): Your key · Spare · Lock.
/// Each part turns green once done; the current one is orange.
struct KeyStepsStrip: View {
    enum Part: Int, CaseIterable { case key, spare, lock }
    let current: Part

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Part.allCases, id: \.self) { part in
                let done = part.rawValue < current.rawValue
                let now = part == current
                HStack(spacing: 6) {
                    Image(systemName: done ? "checkmark.circle.fill" : icon(part))
                        .font(.appSystem(size: 13, weight: .semibold))
                    Text(label(part))
                        .font(.appSystem(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundColor(done ? WizardColors.success : (now ? WizardColors.accentPrimary : WizardColors.textMuted))
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(Capsule().fill(now ? WizardColors.accentPrimary.opacity(0.12) : WizardColors.bgCard))
                .overlay(Capsule().stroke(now ? WizardColors.borderActive : WizardColors.borderSubtle, lineWidth: 1))
                if part != .lock {
                    Rectangle()
                        .fill(done ? WizardColors.success : WizardColors.borderSubtle)
                        .frame(width: 10, height: 1.5)
                        .accessibilityHidden(true)
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of 3: \(label(current))")
    }

    private func label(_ part: Part) -> String {
        switch part {
        case .key: return "Your key"
        case .spare: return "Spare"
        case .lock: return "Lock"
        }
    }

    private func icon(_ part: Part) -> String {
        switch part {
        case .key: return "key.fill"
        case .spare: return "doc.on.doc.fill"
        case .lock: return "lock.fill"
        }
    }
}
