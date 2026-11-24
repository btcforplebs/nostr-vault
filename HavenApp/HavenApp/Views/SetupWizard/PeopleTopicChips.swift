import SwiftUI

/// The people step's topic chips: the hashtags the offered people share
/// (`ReferralSuggestions.topics`). Tapping one shows only the people who use
/// it; tapping it again, or All, shows everyone. Scrolls sideways when the
/// chips don't fit. Styled like the Welcome step's chips.
struct PeopleTopicChips: View {
    let topics: [String]
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, "All")
                ForEach(topics, id: \.self) { chip($0, "#\($0)") }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func chip(_ topic: String?, _ label: String) -> some View {
        let on = selected == topic
        return Button {
            withAnimation(WizardAnimations.springGentle) { selected = (on && topic != nil) ? nil : topic }
        } label: {
            Text(label)
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(on ? .white : WizardColors.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(Capsule().fill(on ? AnyShapeStyle(WizardColors.accentGradient) : AnyShapeStyle(WizardColors.bgCard)))
                .overlay(Capsule().stroke(on ? Color.clear : WizardColors.borderSubtle, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(topic.map { "Topic \($0)" } ?? "All topics")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
