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

/// The line a filter tap leaves under the toolbar, in one grammar for every
/// screen: "what it does · current setting [· count]", e.g.
/// "Global · Web of Trust on", "Mentions · on · 214+". A filter turned off
/// keeps its own icon, dimmed, so the "what it does" half still reads.
struct FilterNote: Equatable {
    let icon: String
    let text: String
    /// An off setting: the icon and text drop to secondary.
    var dimmed: Bool = false

    /// Free text; prefer `init(icon:title:setting:count:)` for the grammar.
    init(icon: String, text: String, dimmed: Bool = false) {
        self.icon = icon
        self.text = text
        self.dimmed = dimmed
    }

    /// "Title · setting", with an optional count last ("Mentions · on · 18").
    init(icon: String, title: String, setting: String, count: String? = nil) {
        var parts = [title, setting]
        if let count, !count.isEmpty { parts.append(count) }
        self.init(icon: icon, text: parts.joined(separator: " · "))
    }

    /// A filter turned back off: "Title · off" with the button's own icon.
    static func off(_ title: String, icon: String) -> FilterNote {
        FilterNote(icon: icon, text: "\(title) · off", dimmed: true)
    }

    /// A filter turned back off, without its icon.
    @available(*, deprecated, message: "Pass the button's own icon: .off(title, icon:)")
    static func off(_ title: String) -> FilterNote {
        FilterNote(icon: "circle.slash", text: "\(title) off")
    }
}

/// Holds the showing note. `show` is a tap: the text replaces cleanly and
/// the one 2 s timer restarts. `update` is a late result (a count that
/// landed): it changes the text only while the note is still showing and
/// is a no-op once it has gone, so the pill never pops back. VoiceOver
/// reads each out, since it's the only text the tap leaves.
@MainActor
final class FilterNoteModel: ObservableObject {
    @Published private(set) var note: FilterNote?
    private var fade: Task<Void, Never>?

    func show(_ note: FilterNote) {
        withAnimation(Motion.fade) { self.note = note }
        AccessibilityNotification.Announcement(note.text).post()
        restartTimer()
    }

    func update(_ note: FilterNote) {
        guard self.note != nil else { return }
        withAnimation(Motion.fade) { self.note = note }
        AccessibilityNotification.Announcement(note.text).post()
        restartTimer()
    }

    func hide() {
        fade?.cancel()
        fade = nil
        withAnimation(Motion.fade) { note = nil }
    }

    private func restartTimer() {
        fade?.cancel()
        fade = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.fade) { self?.note = nil }
        }
    }
}

/// The glass capsule for a `FilterNoteModel`'s note; nothing when none.
/// One line, cut off with "…" past `maxWidth` (a 375 pt phone minus 16 pt
/// margins). Never takes taps, so it can sit over the content. Fades in
/// with a slight scale from its top edge, not a slide from under the bar;
/// Reduce Motion gets the fade alone.
struct FilterNoteView: View {
    @ObservedObject var model: FilterNoteModel
    static let maxWidth: CGFloat = 343

    var body: some View {
        if let note = model.note {
            HStack(spacing: 7) {
                Image(systemName: note.icon).font(.appSystem(size: 12, weight: .bold))
                    .foregroundColor(note.dimmed ? .secondary : .havenPurple)
                Text(note.text).monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(note.dimmed ? .secondary : .primary)
            }
            .font(.appSystem(size: 13, weight: .semibold))
            .padding(.vertical, 7)
            .padding(.horizontal, 14)
            .frame(maxWidth: Self.maxWidth)
            .fixedSize(horizontal: true, vertical: false)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
            // A second tap swaps the text in place, not mid-transition.
            .contentTransition(.opacity)
            .animation(Motion.fade, value: note)
            .allowsHitTesting(false)
            // Announced when shown; as an element it would be read twice.
            .accessibilityHidden(true)
            .transition(Motion.isReduced
                ? .opacity
                : .opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
        }
    }
}

extension View {
    /// Hosts a screen's filter note: an overlay pinned to the top edge of
    /// the content, so it sits in the gap under the toolbar above the first
    /// post. Never in the layout flow, so a tap moves nothing; when the
    /// list is scrolled it may sit over content, and still takes no taps.
    /// Apply once per screen, on the content view under the toolbar.
    func filterNoteHost(_ model: FilterNoteModel) -> some View {
        overlay(alignment: .top) {
            FilterNoteView(model: model).padding(.top, 8)
        }
    }
}
