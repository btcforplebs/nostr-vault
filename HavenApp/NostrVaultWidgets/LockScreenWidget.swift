import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Lock Screen
//
// accessoryCircular / accessoryRectangular / accessoryInline.
//
// These render monochrome and are vended into a tinted context, so colour is
// not available as a channel here -- shape, weight and gauge fill have to carry
// the meaning. Everything is drawn with .widgetAccentable and system fonts so
// it inherits whatever tint the user's Lock Screen is using.

enum LockMetric: String, AppEnum {
    case mentions, dms, events, zaps, relay

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Show" }
    static var caseDisplayRepresentations: [LockMetric: DisplayRepresentation] = [
        .mentions: "Unread mentions",
        .dms: "Unread messages",
        .events: "Events stored",
        .zaps: "Zaps today",
        .relay: "Relay status",
    ]
}

struct LockScreenIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Vault Lock Screen"
    static var description = IntentDescription("One number from your vault, on the Lock Screen.")

    @Parameter(title: "Show", default: .mentions)
    var metric: LockMetric
}

struct LockScreenEntry: TimelineEntry {
    let date: Date
    let snapshot: NVWidgetSnapshot
    let config: LockScreenIntent
}

struct LockScreenProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> LockScreenEntry {
        LockScreenEntry(date: Date(), snapshot: .preview, config: LockScreenIntent())
    }

    func snapshot(for configuration: LockScreenIntent, in context: Context) async -> LockScreenEntry {
        LockScreenEntry(date: Date(), snapshot: NVSharedStore.load() ?? .preview, config: configuration)
    }

    func timeline(for configuration: LockScreenIntent, in context: Context) async -> Timeline<LockScreenEntry> {
        let now = Date()
        let entry = LockScreenEntry(date: now, snapshot: NVSharedStore.load() ?? .empty, config: configuration)
        // Reload at midnight too, so Zaps today drops to 0 on time.
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: NVZapsToday.startOfDay(now)) ?? now
        return Timeline(entries: [entry], policy: .after(min(now.addingTimeInterval(15 * 60), midnight)))
    }
}

struct LockScreenView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LockScreenEntry

    private var snapshot: NVWidgetSnapshot { entry.snapshot }

    private var icon: String {
        switch entry.config.metric {
        case .mentions: return "at"
        case .dms: return "envelope.fill"
        case .events: return "tray.full.fill"
        case .zaps: return "bolt.fill"
        case .relay: return snapshot.relay.isRunning ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var value: String {
        switch entry.config.metric {
        case .mentions: return "\(snapshot.mentions.count)"
        case .dms: return "\(snapshot.unreadDMCount)"
        case .events: return NV.compactCount(snapshot.relay.eventCount)
        case .zaps: return "\(snapshot.wallet.zapsToday(at: entry.date))"
        case .relay: return snapshot.relay.isRunning ? "Live" : "Off"
        }
    }

    private var label: String {
        switch entry.config.metric {
        case .mentions: return "mentions"
        case .dms: return "messages"
        case .events: return "events"
        case .zaps: return "zaps today"
        case .relay: return "relay"
        }
    }

    private var link: NVDeepLink {
        switch entry.config.metric {
        case .mentions: return .mentions
        case .dms: return .dms
        case .events, .relay: return .relay
        case .zaps: return .wallet
        }
    }

    /// Circular gets a gauge, so it needs a 0-1 position. Counts have no
    /// natural ceiling, so these are soft scales chosen to look sensible at
    /// everyday values rather than to be numerically meaningful.
    private var gaugeFraction: Double {
        switch entry.config.metric {
        case .mentions: return min(Double(snapshot.mentions.count) / 10, 1)
        case .dms: return min(Double(snapshot.unreadDMCount) / 10, 1)
        case .zaps: return min(Double(snapshot.wallet.zapsToday(at: entry.date)) / 50, 1)
        case .events: return min(Double(snapshot.relay.eventCount) / 100_000, 1)
        case .relay: return snapshot.relay.isRunning ? 1 : 0
        }
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Gauge(value: gaugeFraction) {
                    Image(systemName: icon)
                } currentValueLabel: {
                    Text(value).font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .gaugeStyle(.accessoryCircular)

            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                        Text("Nostr Vault").font(.system(size: 12, weight: .semibold))
                    }
                    .widgetAccentable()
                    Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            default: // accessoryInline
                // Inline is a single line next to the clock and silently
                // truncates, so it gets the shortest phrasing available.
                Label("\(value) \(label)", systemImage: icon)
            }
        }
        .widgetURL(link.url)
    }
}

struct LockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "VaultLockScreen", intent: LockScreenIntent.self, provider: LockScreenProvider()) { entry in
            LockScreenView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Nostr Vault")
        .description("Mentions, messages, zaps or relay status on the Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
