import SwiftUI

// MARK: - Vault tab

/// Which half of the Vault tab is showing: the relay's lists (Notes, Articles,
/// Highlights, Likes, Zaps, Followers) or the Blossom media gallery. The tab
/// bar's corner button reads it to open the matching dashboard.
final class VaultSection: ObservableObject {
    static let shared = VaultSection()
    /// Any write here also leaves the Emoji page: every path that picks the
    /// Media or relay half means "not Emoji".
    @Published var showsMedia = false { didSet { if showsEmoji { showsEmoji = false } } }
    /// The Emoji page (EmojiVaultView) is showing, over both halves.
    @Published var showsEmoji = false
    /// Modes with something new, published by the relay half so the pill
    /// shows the same dots on the Media half.
    @Published var newModes: Set<VaultMode> = []
    /// Whether the Vault tab is the one on screen. The iOS shell sets it from
    /// the selected tab; a mode only counts as seen while it's in sight.
    @Published var isOnScreen = false
    /// Set when you tap into the Vault tab: it then opens the list its red
    /// dot is for, instead of whichever one you left it on.
    @Published var opensNewActivity = false
    /// The relay half's list on screen (Media aside), for the tab's hold menu.
    @Published var listMode: VaultMode = .activity
    /// A page picked from the tab's hold menu, for the relay half to open.
    @Published var pendingMode: VaultMode?
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
    /// The gallery is built the first time Media shows, then kept. Until then
    /// a Vault visit doesn't pay for its thumbnails, rescan and mirroring.
    @State private var mediaBuilt = false

    private var notesShow: Bool { !section.showsMedia && !section.showsEmoji }

    var body: some View {
        ZStack {
            notes()
                .opacity(notesShow ? 1 : 0)
                .allowsHitTesting(notesShow)
                .accessibilityHidden(!notesShow)
            if mediaBuilt || section.showsMedia {
                MediaTabView()
                    .opacity(section.showsMedia ? 1 : 0)
                    .allowsHitTesting(section.showsMedia)
                    .accessibilityHidden(!section.showsMedia)
            }
            // Built only while shown: it holds no scroll worth keeping.
            if section.showsEmoji {
                EmojiVaultView()
                    .transition(.opacity)
            }
        }
        .environment(\.inVaultTab, true)
        .onChange(of: section.showsMedia, initial: true) { _, shows in
            if shows { mediaBuilt = true }
        }
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
    /// "Vault": everything that came in, in one list, like a notifications
    /// page. The tab opens on it.
    case activity
    case notes, articles, highlights, media
    /// Saved custom emoji sets (EmojiVaultView), kept out of Media.
    case emoji
    case likes, zaps, bookmarks, followers
    /// The inbox, as a page of its own (Logen 2026-11-03): no toolbar
    /// envelope, no sheet. Last, so the tab's hold menu has it on top.
    case messages

    var title: String { self == .activity ? "Vault" : rawValue.capitalized }

    var symbol: String {
        switch self {
        case .activity: return "tray.full.fill"
        case .notes: return "doc.text"
        case .articles: return "doc.richtext"
        case .highlights: return "highlighter"
        case .media: return "photo.on.rectangle"
        case .emoji: return "face.smiling"
        case .likes: return "heart.fill"
        case .zaps: return "bolt.fill"
        case .bookmarks: return "bookmark.fill"
        case .followers: return "person.2.fill"
        case .messages: return "envelope.fill"
        }
    }

    /// Where an inbound event of `kind` from someone else shows up. Nil for
    /// DMs, which the Messages button's dot covers, and for kinds no list shows.
    static func listing(inboxKind kind: Int) -> VaultMode? {
        switch kind {
        case 7: return .likes
        case 9735: return .zaps
        case VaultNoteScope.articleKind: return .articles
        case VaultNoteScope.highlightKind: return .highlights
        default: return NostrService.relayTabNoteKinds.contains(kind) ? .notes : nil
        }
    }

    @MainActor
    func select() {
        switch self {
        case .activity: NotificationCenter.default.post(name: .havenOpenRelayActivity, object: nil)
        case .notes: NotificationCenter.default.post(name: .havenOpenRelayNotes, object: VaultNoteScope.notes)
        case .articles: NotificationCenter.default.post(name: .havenOpenRelayNotes, object: VaultNoteScope.articles)
        case .highlights: NotificationCenter.default.post(name: .havenOpenRelayNotes, object: VaultNoteScope.highlights)
        case .likes: NotificationCenter.default.post(name: .havenOpenRelayLikes, object: nil)
        case .zaps: NotificationCenter.default.post(name: .havenOpenRelayZaps, object: nil)
        case .bookmarks: NotificationCenter.default.post(name: .havenOpenRelayBookmarks, object: nil)
        case .followers: NotificationCenter.default.post(name: .havenOpenRelayFollowers, object: nil)
        case .messages: DMInboxRoute.shared.open(nil)
        case .media, .emoji: break
        }
        withAnimation(Motion.toggle) {
            VaultSection.shared.showsMedia = self == .media
            VaultSection.shared.showsEmoji = self == .emoji
        }
    }
}

/// The Vault tab's mode picker, built like the Feed tab's: the mode's icon,
/// its name, and a chevron. The menu lists the
/// modes, then the Vault Dashboard, as the feed menu ends with its dashboard.
struct VaultModePill: View {
    let mode: VaultMode
    var zapsOnly = false
    @ObservedObject private var section = VaultSection.shared
    @ObservedObject private var dmService = DMService.shared
    @EnvironmentObject var relayManager: RelayProcessManager

    /// Modes with something new since you last looked: the relay half's own
    /// dots, what others sent that lit the Vault tab's dot, and Messages
    /// while one is unread.
    private var newModes: Set<VaultMode> {
        var modes = section.newModes.union(relayManager.newActivityModes)
        if dmService.totalUnreadCount > 0 { modes.insert(.messages) }
        return modes
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
                        // Messages says how many; the other pages only that something is new.
                        if m == .messages, dmService.totalUnreadCount > 0 {
                            Text("\(dmService.totalUnreadCount) unread")
                        } else if newModes.contains(m) {
                            Text("New")
                        }
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
        .accessibilityHint("Switch between everything new, notes, articles, highlights, media, emoji, likes, zaps, bookmarks, followers and messages, or open the Vault Dashboard")
    }
}

/// Opens the Messages page of the Vault, on `peer`'s conversation when one is
/// given: notifications, the widget, Your space and the menus all come here.
/// The request waits until the Vault and its inbox are built to take it.
@MainActor
final class DMInboxRoute: ObservableObject {
    static let shared = DMInboxRoute()
    /// Bumped per request; the Vault switches to Messages when it changes.
    @Published private(set) var request = 0
    private var peer: String?

    func open(_ peer: String?) {
        self.peer = peer
        request &+= 1
        withAnimation(Motion.toggle) { VaultSection.shared.showsMedia = false }
    }

    private var handledRequest = 0

    /// True once per request: the Vault that takes it switches to Messages.
    func takeRequest() -> Bool {
        guard request != handledRequest else { return false }
        handledRequest = request
        return true
    }

    /// The conversation to open, once.
    func takePeer() -> String? {
        defer { peer = nil }
        return peer
    }
}
