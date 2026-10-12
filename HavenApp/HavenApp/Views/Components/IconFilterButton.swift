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
/// When the line is too long for the screen, the title is what gets cut;
/// the setting and count always show whole.
struct FilterNote: Equatable {
    let icon: String
    /// What the button does. The only part that truncates.
    let title: String
    /// "setting [· count]", kept whole after the title.
    let detail: String?
    /// An off setting: the icon and text drop to secondary.
    var dimmed: Bool = false

    /// The whole line, as read out.
    var text: String { detail.map { "\(title) · \($0)" } ?? title }

    /// Free text; prefer `init(icon:title:setting:count:)` for the grammar.
    init(icon: String, text: String, dimmed: Bool = false) {
        self.icon = icon
        self.title = text
        self.detail = nil
        self.dimmed = dimmed
    }

    /// "Title · setting", with an optional count last ("Mentions · on · 18").
    init(icon: String, title: String, setting: String, count: String? = nil, dimmed: Bool = false) {
        var parts = [setting]
        if let count, !count.isEmpty { parts.append(count) }
        self.icon = icon
        self.title = title
        self.detail = parts.joined(separator: " · ")
        self.dimmed = dimmed
    }

    /// A filter turned back off: "Title · off" with the button's own icon.
    static func off(_ title: String, icon: String) -> FilterNote {
        FilterNote(icon: icon, title: title, setting: "off", dimmed: true)
    }

    /// A filter turned back off, without its icon.
    @available(*, deprecated, message: "Pass the button's own icon: .off(title, icon:)")
    static func off(_ title: String) -> FilterNote {
        FilterNote(icon: "circle.slash", text: "\(title) off")
    }
}

/// Holds the showing note. `show` is a tap: the text replaces cleanly and
/// the one 2 s timer restarts. `update` is a late result (a count that
/// landed): it changes the text only while the note is still showing, keeps
/// the time left (raised to a short floor so the count is readable, never
/// past a cap after the tap), and is a no-op once the note has gone, so
/// the pill never pops back and a repeating signal can't pin it.
/// VoiceOver reads each out, since it's the only text the tap leaves.
@MainActor
final class FilterNoteModel: ObservableObject {
    @Published private(set) var note: FilterNote?
    /// `show()` gives the pill this long.
    static let duration: Duration = .seconds(2)
    /// `update()` leaves at least this long, so a late count is readable…
    static let updateFloor: Duration = .milliseconds(800)
    /// …but never past this long after `show()`, so a repeating signal
    /// cannot pin the pill.
    static let maxDuration: Duration = .seconds(6)
    private var fade: Task<Void, Never>?
    private var shownAt: ContinuousClock.Instant?
    private var hidesAt: ContinuousClock.Instant?

    func show(_ note: FilterNote) {
        withAnimation(Motion.fade) { self.note = note }
        AccessibilityNotification.Announcement(note.text).post()
        let now = ContinuousClock.now
        shownAt = now
        hide(at: now + Self.duration)
    }

    func update(_ note: FilterNote) {
        guard self.note != nil, let hidesAt, let shownAt else { return }
        withAnimation(Motion.fade) { self.note = note }
        AccessibilityNotification.Announcement(note.text).post()
        // Keep the time left, extended to the floor, within the cap.
        let floor = min(ContinuousClock.now + Self.updateFloor, shownAt + Self.maxDuration)
        if floor > hidesAt { hide(at: floor) }
    }

    func hide() {
        fade?.cancel()
        fade = nil
        hidesAt = nil
        withAnimation(Motion.fade) { note = nil }
    }

    private func hide(at instant: ContinuousClock.Instant) {
        hidesAt = instant
        fade?.cancel()
        fade = Task { [weak self] in
            try? await Task.sleep(until: instant, clock: .continuous)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.fade) { self?.note = nil }
        }
    }
}

/// Lays the title and the "· setting · count" detail on one line. When they
/// fit, each takes its natural width. When they don't, the title gives way
/// first, down to `titleFloor` or its full text, whichever is less; past
/// that the detail is what gets cut. So "Lan… · English, Spanish,
/// Portuguese, German" becomes "Languages · English, Spanish, Portu…", and
/// nothing shrinks to a bare "L". With one subview it just hugs it.
struct FilterNoteLine: Layout {
    /// The least width the title keeps once both halves can't fit.
    static let titleFloor: CGFloat = 72

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(proposal: proposal, subviews: subviews)
        let height = zip(subviews, widths)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: proposal.height)).height }
            .max() ?? 0
        return CGSize(width: widths.reduce(0, +), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(proposal: proposal, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }

    /// Each subview's width: its natural width when they fit, else the
    /// split above, then narrowed to what the subview takes at that
    /// proposal, so a cut title ends where its "…" does.
    private func widths(proposal: ProposedViewSize, subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        guard let available = proposal.width, subviews.count == 2, ideal.reduce(0, +) > available else {
            return ideal.map { min($0, proposal.width ?? $0) }
        }
        let title = min(available, max(available - ideal[1], min(ideal[0], Self.titleFloor)))
        return zip(subviews, [title, max(available - title, 0)]).map { subview, width in
            min(width, subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).width)
        }
    }
}

/// The glass capsule for a `FilterNoteModel`'s note; nothing when none.
/// One line that hugs its text up to the host's width minus 16 pt margins,
/// so it follows the text-size setting; past that the title is cut with
/// "…" down to `FilterNoteLine.titleFloor`, then the setting and count are
/// cut the same way, so neither half vanishes. Never takes taps, so it can
/// sit over the content. Fades in with a slight scale from its top edge,
/// not a slide from under the bar; Reduce Motion gets the fade alone.
struct FilterNoteView: View {
    @ObservedObject var model: FilterNoteModel
    /// The dimmed (off) look, the same on Android.
    static let dimmedOpacity = 0.55
    /// Where the pill's bottom edge sits, below the host's top edge (plus
    /// any `topInset`), at every text size. On an iPhone the content starts
    /// about 10 pt under the bar and the first post about 18 pt under that,
    /// so the bottom lands 6 pt above the post; at 100% the 26 pt pill then
    /// reaches 4 pt into the glass. A bigger pill grows upward behind the
    /// bar, where it is hidden, never down over the post. On macOS the
    /// header is in the content, not above it, so there the pill sits just
    /// under it instead (see `filterNoteHost`).
    static let bottomEdge: CGFloat = 12

    var body: some View {
        if let note = model.note {
            HStack(spacing: 7) {
                Image(systemName: note.icon).font(.appSystem(size: 12, weight: .bold))
                    .foregroundColor(note.dimmed ? .primary.opacity(Self.dimmedOpacity) : .havenPurple)
                FilterNoteLine {
                    Text(note.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let detail = note.detail {
                        Text(" · \(detail)")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .monospacedDigit()
                .foregroundColor(note.dimmed ? .primary.opacity(Self.dimmedOpacity) : .primary)
            }
            .font(.appSystem(size: 13, weight: .semibold))
            // 26 pt tall: fits the gap between the toolbar and the first post.
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
            // The margins: the capsule never gets wider than the host minus these.
            .padding(.horizontal, 16)
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
    /// the content, with the pill's bottom edge `FilterNoteView.bottomEdge`
    /// below it, so the bottom stays above the first post at every text
    /// size and the top overlaps the toolbar glass, more so as the text
    /// grows. Never in the layout flow, so a tap moves nothing; when the
    /// list is scrolled it may sit over content, and still takes no taps.
    /// Apply once per screen, on the content view under the toolbar. When
    /// the screen draws its own header inside that content (the Mac Vault),
    /// pass the header's height as `topInset`. On macOS the pill then sits
    /// just under that header with no rise: the header is in flow, and the
    /// overlay would paint over it rather than slip behind it.
    func filterNoteHost(_ model: FilterNoteModel, topInset: CGFloat = 0) -> some View {
        overlay(alignment: .top) {
            #if os(macOS)
            FilterNoteView(model: model)
                .padding(.top, topInset)
            #else
            FilterNoteView(model: model)
                // A slot of fixed height; the pill is aligned to its bottom
                // and overflows upward when it is taller.
                .frame(height: FilterNoteView.bottomEdge, alignment: .bottom)
                .padding(.top, topInset)
            #endif
        }
    }
}
