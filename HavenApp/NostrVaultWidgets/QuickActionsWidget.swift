import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Quick Actions
//
// Deep-link tiles. Each tile is its own Link, so a tap opens the screen it
// shows rather than just reopening the app -- which is the entire reason this
// widget is worth a Home Screen slot over the app icon.

enum QuickAction: String, AppEnum, CaseIterable {
    case compose, dms, search, relay, media, wallet

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Action" }
    static var caseDisplayRepresentations: [QuickAction: DisplayRepresentation] = [
        .compose: "New note",
        .dms: "Messages",
        .search: "Search",
        .relay: "Relay",
        .media: "Media",
        .wallet: "Wallet",
    ]

    var icon: String {
        switch self {
        case .compose: return "square.and.pencil"
        case .dms: return "envelope.fill"
        case .search: return "magnifyingglass"
        case .relay: return "antenna.radiowaves.left.and.right"
        case .media: return "photo.on.rectangle"
        case .wallet: return "bolt.fill"
        }
    }

    var label: String {
        switch self {
        case .compose: return "Post"
        case .dms: return "DMs"
        case .search: return "Search"
        case .relay: return "Relay"
        case .media: return "Media"
        case .wallet: return "Wallet"
        }
    }

    var tint: Color {
        switch self {
        // One orange ramp, dark to soft; the wallet keeps the zap gold.
        case .compose: return NV.orange
        case .dms: return NV.orangeMid
        case .search: return NV.orangeLight
        case .relay: return NV.orangeDark
        case .media: return NV.orangeSoft
        case .wallet: return NV.zapGold
        }
    }

    var link: NVDeepLink {
        switch self {
        case .compose: return .compose
        case .dms: return .dms
        case .search: return .search
        case .relay: return .relay
        case .media: return .media
        case .wallet: return .wallet
        }
    }
}

struct QuickActionsIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Quick Actions"
    static var description = IntentDescription("Tiles that open straight into the screen you want.")

    @Parameter(title: "First", default: .compose)
    var slot1: QuickAction
    @Parameter(title: "Second", default: .dms)
    var slot2: QuickAction
    @Parameter(title: "Third", default: .search)
    var slot3: QuickAction
    @Parameter(title: "Fourth", default: .relay)
    var slot4: QuickAction
}

struct QuickActionsEntry: TimelineEntry {
    let date: Date
    let snapshot: NVWidgetSnapshot
    let config: QuickActionsIntent
}

struct QuickActionsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuickActionsEntry {
        QuickActionsEntry(date: Date(), snapshot: .preview, config: QuickActionsIntent())
    }

    func snapshot(for configuration: QuickActionsIntent, in context: Context) async -> QuickActionsEntry {
        QuickActionsEntry(date: Date(), snapshot: NVSharedStore.load() ?? .preview, config: configuration)
    }

    func timeline(for configuration: QuickActionsIntent, in context: Context) async -> Timeline<QuickActionsEntry> {
        let entry = QuickActionsEntry(date: Date(), snapshot: NVSharedStore.load() ?? .empty, config: configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
    }
}

struct QuickActionsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickActionsEntry

    /// Small shows two tiles, medium four. Cramming four into a small slot
    /// leaves tap targets under the 44pt minimum.
    private var actions: [QuickAction] {
        let all = [entry.config.slot1, entry.config.slot2, entry.config.slot3, entry.config.slot4]
        return family == .systemSmall ? Array(all.prefix(2)) : all
    }

    var body: some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        LazyVGrid(columns: family == .systemSmall ? [GridItem(.flexible())] : columns, spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Link(destination: action.link.url) {
                    Tile(action: action, badge: badge(for: action))
                }
            }
        }
    }

    private func badge(for action: QuickAction) -> Int? {
        guard action == .dms, entry.snapshot.unreadDMCount > 0 else { return nil }
        return entry.snapshot.unreadDMCount
    }
}

private struct Tile: View {
    let action: QuickAction
    let badge: Int?

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: action.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(action.tint)
                    .frame(width: 30, height: 30)
                    .background(action.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                if let badge {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                        .offset(x: 6, y: -5)
                }
            }
            Text(action.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

struct QuickActionsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "QuickActions", intent: QuickActionsIntent.self, provider: QuickActionsProvider()) { entry in
            QuickActionsView(entry: entry)
                .containerBackground(NV.background, for: .widget)
        }
        .configurationDisplayName("Quick Actions")
        .description("Jump straight to compose, messages, search or the relay.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
