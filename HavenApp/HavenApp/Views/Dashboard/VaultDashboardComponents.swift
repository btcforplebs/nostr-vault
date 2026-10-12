import SwiftUI

// MARK: - Building blocks

/// A titled card of rows: the section style every Vault Dashboard block uses.
struct DashboardSection<Content: View>: View {
    let title: String
    var detail: String?
    /// Off for content that draws its own cards, like the tiles.
    var framed = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.appSystem(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if framed {
                VStack(spacing: 0) { content }
                    .background(Color.platformCardBackground, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.platformCardBorder, lineWidth: 1))
            } else {
                content
            }
        }
    }
}

struct DashboardDivider: View {
    var body: some View { Divider().padding(.leading, 52) }
}

enum RowState {
    case done, todo, info

    @MainActor var color: Color {
        switch self {
        case .done: return .havenOnline
        case .todo: return .orange
        case .info: return .havenPurple
        }
    }
}

struct RowIcon: View {
    let icon: String
    let state: RowState

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: icon)
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(state.color)
                .frame(width: 30, height: 30)
                .background(state.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            if state != .info {
                Image(systemName: state == .done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.appSystem(size: 12, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, state.color)
                    .offset(x: 4, y: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

struct RowText: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(.primary)
            Text(detail)
                .font(.appSystem(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row with a trailing control (a button) and an optional progress bar.
struct DashboardRow<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String
    let state: RowState
    var progress: Double?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                RowIcon(icon: icon, state: state)
                RowText(title: title, detail: detail)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(state == .todo ? "Needs attention" : state == .done ? "Done" : "")
                trailing
            }
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(.havenPurple)
                    .padding(.leading, 42)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// A row that opens a settings page.
struct DashboardRowLink<Destination: View>: View {
    let icon: String
    let title: String
    let detail: String
    let state: RowState
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                RowIcon(icon: icon, state: state)
                RowText(title: title, detail: detail)
                if state == .todo {
                    Text("Fix")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                }
                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(state == .todo ? "Needs attention" : state == .done ? "Done" : "")
    }
}

struct RowLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(.havenPurple)
                .frame(width: 30, height: 30)
                .background(Color.havenPurple.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(title)
                .font(.appSystem(size: 15, weight: .medium))
                .foregroundColor(.primary)
        }
    }
}

/// A quick link to one of the vault's own settings, showing its current value.
struct SettingLink<Destination: View>: View {
    let icon: String
    let title: String
    let value: String?
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 8) {
                RowLabel(icon: icon, title: title)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.appSystem(size: 15))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct RowButton: View {
    let title: String
    var isLoading = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isLoading ? 0 : 1)
                if isLoading { ProgressView().controlSize(.small) }
            }
            .font(.appSystem(size: 13, weight: .semibold))
            .foregroundColor(.havenPurple)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(Color.havenPurple.opacity(0.12), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

extension View {
    /// A settings page pushed from the dashboard, titled like it is in Settings.
    func settingsPage(_ title: String) -> some View {
        navigationTitle(title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
