import SwiftUI

/// The Search tab's top-right control: one compact menu with the "who" and
/// "when" filters. A bare funnel when nothing is filtered, a filled one
/// when something is; `SearchFilterCaption` spells it out.
struct SearchFilterMenu: View {
    @Binding var scope: SearchFilter
    let color: Color

    var body: some View {
        Menu {
            SearchFilterMenuItems(scope: $scope)
        } label: {
            // Fixed width on purpose: a label that grows when a filter is on
            // overflows the iOS 26 toolbar and the whole item collapses to
            // "…". The caption under the search field says what is on.
            Image(systemName: scope.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(scope.isActive ? color : .secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
                .animation(Motion.toggle, value: scope)
        }
        .menuIndicator(.hidden)
        #if os(iOS)
        // Stays open so who and when can be set in one visit.
        .menuActionDismissBehavior(.disabled)
        #endif
        #if os(macOS)
        // .borderlessButton flattens the label's modifiers on macOS.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help(scope.accessibilitySummary)
        #endif
        .accessibilityLabel("Filter")
        .accessibilityValue(scope.accessibilitySummary)
    }
}

/// The rows of the filter menu: a "who" section, a "when" section, and a
/// reset once anything is on.
struct SearchFilterMenuItems: View {
    @Binding var scope: SearchFilter

    var body: some View {
        Section("Who") {
            ForEach(SearchFilter.Who.allCases, id: \.self) { who in
                Button {
                    scope.who = who
                } label: {
                    Label(who.label, systemImage: scope.who == who ? "checkmark" : who.icon)
                }
            }
        }
        Section("When") {
            ForEach(SearchFilter.When.allCases, id: \.self) { when in
                Button {
                    scope.when = when
                } label: {
                    Label(when.label, systemImage: scope.when == when ? "checkmark" : when.icon)
                }
            }
        }
        if scope.isActive {
            Divider()
            Button(role: .destructive) {
                scope = .all
            } label: {
                Label("Clear filter", systemImage: "xmark.circle")
            }
        }
    }
}

/// The line under the search field while a filter is on: "People you follow
/// · Last week", with a Clear at the end. Gone when nothing is filtered.
struct SearchFilterCaption: View {
    @Binding var scope: SearchFilter
    let color: Color

    var body: some View {
        if scope.isActive {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .font(.appSystem(size: 11, weight: .semibold))
                    .foregroundColor(color)
                Text(scope.accessibilitySummary)
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Clear filter") {
                    scope = .all
                }
                .font(.appSystem(size: 12, weight: .semibold))
                .foregroundColor(color)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .accessibilityElement(children: .contain)
        }
    }
}
