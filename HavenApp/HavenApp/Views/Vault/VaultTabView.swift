import SwiftUI

// MARK: - Vault tab

/// Which half of the Vault tab is showing: the relay's lists (Notes, Articles,
/// Highlights, Likes, Zaps, Followers) or the Blossom media gallery. The tab
/// bar's corner button reads it to open the matching dashboard.
final class VaultSection: ObservableObject {
    static let shared = VaultSection()
    @Published var showsMedia = false
    /// Modes with something new, published by the relay half so the pill
    /// shows the same dots on the Media half.
    @Published var newModes: Set<VaultMode> = []
}

private struct InVaultTabKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True inside the Vault tab, where Media is one of the relay's modes and
    /// the mode switch is the dropdown pill.
    var inVaultTab: Bool {
        get { self[InVaultTabKey.self] }
        set { self[InVaultTabKey.self] = newValue }
    }
}

/// What used to be the Media and Relay tabs, in one. Both stay alive so
/// switching is instant and each keeps its scroll position and filters.
struct VaultTabView<Notes: View>: View {
    @ObservedObject private var section = VaultSection.shared
    /// The relay half. iPad wraps it in the note split; the phone uses it as is.
    @ViewBuilder let notes: () -> Notes

    var body: some View {
        ZStack {
            notes()
                .opacity(section.showsMedia ? 0 : 1)
                .allowsHitTesting(!section.showsMedia)
                .accessibilityHidden(section.showsMedia)
            MediaTabView()
                .opacity(section.showsMedia ? 1 : 0)
                .allowsHitTesting(section.showsMedia)
                .accessibilityHidden(!section.showsMedia)
        }
        .environment(\.inVaultTab, true)
    }
}

/// The one dashboard for everything the Vault tab stores: the relay's, with
/// Blossom's sections under it.
enum VaultDashboard {
    static let title = "Vault Dashboard"
    static let symbol = "lock.rectangle.stack"
}

/// The Vault tab's modes, in menu order.
enum VaultMode: String, CaseIterable {
    case notes, articles, highlights, media, likes, zaps, followers

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .notes: return "doc.text"
        case .articles: return "doc.richtext"
        case .highlights: return "highlighter"
        case .media: return "photo.on.rectangle"
        case .likes: return "heart.fill"
        case .zaps: return "bolt.fill"
        case .followers: return "person.2.fill"
        }
    }

    func select() {
        switch self {
        case .notes: NotificationCenter.default.post(name: .havenOpenRelayNotes, object: VaultNoteScope.notes)
        case .articles: NotificationCenter.default.post(name: .havenOpenRelayNotes, object: VaultNoteScope.articles)
        case .highlights: NotificationCenter.default.post(name: .havenOpenRelayNotes, object: VaultNoteScope.highlights)
        case .likes: NotificationCenter.default.post(name: .havenOpenRelayLikes, object: nil)
        case .zaps: NotificationCenter.default.post(name: .havenOpenRelayZaps, object: nil)
        case .followers: NotificationCenter.default.post(name: .havenOpenRelayFollowers, object: nil)
        case .media: break
        }
        withAnimation(Motion.toggle) { VaultSection.shared.showsMedia = self == .media }
    }
}

/// The Vault tab's mode picker, built like the Feed tab's: the mode's icon
/// with the relay's health dot, its name, and a chevron. The menu lists the
/// modes, then the Vault Dashboard, as the feed menu ends with its dashboard.
struct VaultModePill: View {
    let mode: VaultMode
    var zapsOnly = false
    @EnvironmentObject var relayManager: RelayProcessManager
    @ObservedObject private var section = VaultSection.shared

    /// Modes with something new since you last looked.
    private var newModes: Set<VaultMode> { section.newModes }

    private var dotColor: Color {
        if relayManager.isBooting { return .yellow }
        if relayManager.isRunning && relayManager.isWotSyncing { return .orange }
        return relayManager.isRunning ? .green : .red
    }

    private var modes: [VaultMode] {
        VaultMode.allCases.filter { !(zapsOnly && $0 == .likes) }
    }

    /// Something new in a mode you aren't looking at.
    private var hasNewElsewhere: Bool { !newModes.subtracting([mode]).isEmpty }

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { mode }, set: { $0.select() })) {
                ForEach(modes, id: \.self) { m in
                    Label {
                        Text(m.title)
                        if newModes.contains(m) { Text("New") }
                    } icon: {
                        Image(systemName: m.symbol)
                    }
                    .tag(m)
                }
            } label: { EmptyView() }
            .pickerStyle(.inline)

            Divider()

            Button { NotificationCenter.default.post(name: .openRelayDashboard, object: nil) } label: {
                Label(VaultDashboard.title, systemImage: VaultDashboard.symbol)
            }
        } label: {
            HStack(spacing: 0) {
                Image(systemName: mode.symbol)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(dotColor)
                            .frame(width: 8, height: 8)
                            .shadow(color: dotColor.opacity(0.6), radius: 2)
                            .offset(x: -1, y: -1)
                    }
                    .overlay(alignment: .topTrailing) {
                        if hasNewElsewhere {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                                .offset(x: 1, y: 1)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                HStack(spacing: 3) {
                    Text(mode.title)
                        .font(.appSystem(size: 17, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.appSystem(size: 9, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.leading, 8)
                .padding(.trailing, 12)
            }
            .padding(.leading, 7)
            .padding(.vertical, 7)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Vault: \(mode.title)")
        .accessibilityValue(hasNewElsewhere ? "New activity" : "")
        .accessibilityHint("Switch between notes, articles, highlights, media, likes, zaps and followers, or open the Vault Dashboard")
    }
}
