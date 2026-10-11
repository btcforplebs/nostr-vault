import SwiftUI

/// How wide an `IconFilterButton`'s tap target is. A bar that can't fit
/// its row at the usual 36 pt narrows it, so no icon has to go.
private struct FilterButtonWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 36 }
extension EnvironmentValues {
    var filterButtonWidth: CGFloat {
        get { self[FilterButtonWidthKey.self] }
        set { self[FilterButtonWidthKey.self] = newValue }
    }
}

struct IconFilterButton: View {
    @Environment(\.filterButtonWidth) private var width
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
            .frame(minWidth: width, minHeight: 36)
            .contentShape(Rectangle())
            .animation(Motion.toggle, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tooltip)
        #if os(macOS)
        // Icon-only on the Mac too, where hovering is how you find out what
        // an icon does.
        .help(tooltip)
        #endif
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

/// The line a filter tap leaves under the toolbar: the filter's icon and
/// what it did ("214 talk with you", "Mentions off"). Icon-only filters say
/// what you picked here instead of beside the icon.
struct FilterNote: Equatable {
    let icon: String
    let text: String

    /// A filter turned back off.
    static func off(_ title: String) -> FilterNote {
        FilterNote(icon: "circle.slash", text: "\(title) off")
    }
}

/// Holds the showing note. A new one replaces the last; each goes after
/// 2 s. VoiceOver reads it out, since it's the only text the tap leaves.
@MainActor
final class FilterNoteModel: ObservableObject {
    @Published private(set) var note: FilterNote?
    private var fade: Task<Void, Never>?

    func show(_ note: FilterNote) {
        withAnimation(Motion.fade) { self.note = note }
        AccessibilityNotification.Announcement(note.text).post()
        fade?.cancel()
        fade = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.fade) { self?.note = nil }
        }
    }
}

/// The glass capsule for a `FilterNoteModel`'s note; nothing when none.
/// Never takes taps, so it can sit over the content.
struct FilterNoteView: View {
    @ObservedObject var model: FilterNoteModel

    var body: some View {
        if let note = model.note {
            HStack(spacing: 7) {
                Image(systemName: note.icon).font(.appSystem(size: 12, weight: .bold))
                    .foregroundColor(.havenPurple)
                Text(note.text).monospacedDigit()
            }
            .font(.appSystem(size: 13, weight: .semibold))
            .padding(.vertical, 7)
            .padding(.horizontal, 14)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
            .allowsHitTesting(false)
            // Announced when shown; as an element it would be read twice.
            .accessibilityHidden(true)
            .transition(Motion.isReduced ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
    }
}
