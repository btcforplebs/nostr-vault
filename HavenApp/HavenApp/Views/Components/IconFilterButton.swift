import SwiftUI

struct IconFilterButton: View {
    let icon: String
    let tooltip: String
    let isSelected: Bool
    let color: Color
    /// Shown beside the icon while selected, so a row of bare icons still
    /// says which filter is on.
    var label: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if icon == "GIF" {
                    Text("GIF")
                        .font(.appSystem(size: 9, weight: .black, design: .rounded))
                        .foregroundColor(isSelected ? color : .secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(isSelected ? color : Color.secondary, lineWidth: 1.5)
                        )
                } else if isSelected, let label {
                    HStack(spacing: 5) {
                        Image(systemName: icon)
                            .font(.appSystem(size: 15, weight: .semibold))
                        Text(label)
                            .font(.appSystem(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundColor(color)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Capsule().fill(color.opacity(0.16)))
                } else {
                    Image(systemName: icon)
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(isSelected ? color : .secondary)
                }
            }
            .frame(minWidth: 36, minHeight: 36)
            .contentShape(Rectangle())
            .animation(Motion.toggle, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tooltip)
    }
}

/// The Global feed's language picker. Pick any number of languages; none
/// picked shows every language. On iOS the menu stays open between picks
/// so several can be chosen in one go.
struct LanguageFilterMenu: View {
    let selected: [String]
    let color: Color
    let onChange: ([String]) -> Void

    var body: some View {
        Menu {
            LanguageFilterMenuItems(selected: selected, onChange: onChange)
        } label: {
            Image(systemName: selected.isEmpty ? "character.bubble" : "character.bubble.fill")
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(selected.isEmpty ? .secondary : color)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        #if os(iOS)
        .menuActionDismissBehavior(.disabled)
        #endif
        #if os(macOS)
        // .borderlessButton flattens the label's modifiers on macOS.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help(LanguageFilterMenuItems.summary(selected))
        #endif
        .accessibilityLabel("Languages")
        .accessibilityValue(LanguageFilterMenuItems.summary(selected))
    }
}

/// The rows of the language picker, shared by the toolbar button and the
/// compact overflow menu.
struct LanguageFilterMenuItems: View {
    let selected: [String]
    let onChange: ([String]) -> Void

    var body: some View {
        Button {
            onChange([])
        } label: {
            Label("All languages", systemImage: selected.isEmpty ? "checkmark" : "globe")
        }
        Divider()
        ForEach(FeedLanguage.pickerList) { language in
            Button {
                if selected.contains(language.code) {
                    onChange(selected.filter { $0 != language.code })
                } else {
                    onChange(selected + [language.code])
                }
            } label: {
                if selected.contains(language.code) {
                    Label(language.displayName, systemImage: "checkmark")
                } else {
                    Text(language.displayName)
                }
            }
        }
    }

    static func summary(_ selected: [String]) -> String {
        selected.isEmpty
            ? "All languages"
            : selected.map { FeedLanguage(code: $0).displayName }.joined(separator: ", ")
    }
}
