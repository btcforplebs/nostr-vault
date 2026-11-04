import SwiftUI
import WidgetKit

// MARK: - On this day
//
// Your own notes from today's date 1 and 2 years ago (Logen, 2026-11-04), the
// home screen twin of Your space's On this day panel. The app reads them from
// its own vault and hands them over in the snapshot (NVOnThisDaySnapshot);
// this process never fetches. A tap opens the note: small opens the first,
// medium makes every row its own link. One quiet line when there is none.

struct OnThisDayEntry: TimelineEntry {
    let date: Date
    let snapshot: NVWidgetSnapshot
}

struct OnThisDayProvider: TimelineProvider {
    func placeholder(in context: Context) -> OnThisDayEntry {
        OnThisDayEntry(date: Date(), snapshot: .onThisDayPreview)
    }

    func getSnapshot(in context: Context, completion: @escaping (OnThisDayEntry) -> Void) {
        let stored = NVSharedStore.load()
        // The gallery shows the preview until the app has read a day.
        let snapshot = (context.isPreview && stored?.onThisDay == nil) ? .onThisDayPreview : (stored ?? .onThisDayPreview)
        completion(OnThisDayEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OnThisDayEntry>) -> Void) {
        let now = Date()
        let entry = OnThisDayEntry(date: now, snapshot: NVSharedStore.load() ?? .empty)
        // Again at midnight, so yesterday's memories go away on time.
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        completion(Timeline(entries: [entry], policy: .after(min(now.addingTimeInterval(60 * 60), midnight))))
    }
}

struct OnThisDayView: View {
    @Environment(\.widgetFamily) private var family
    let entry: OnThisDayEntry

    private var rows: [(years: Int, note: NVOnThisDaySnapshot.Note)] {
        entry.snapshot.onThisDay?.rows(at: entry.date) ?? []
    }

    var body: some View {
        if !entry.snapshot.hasEverRun {
            NVEmptyState(icon: "clock.arrow.circlepath", message: "Open Nostr Vault to read your past notes")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 5)
                if rows.isEmpty {
                    Text(entry.snapshot.onThisDay == nil ? "Reading your vault…" : "Nothing from this day in past years.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer(minLength: 0)
                } else if family == .systemSmall {
                    small(rows[0])
                } else {
                    medium
                }
            }
            .widgetURL(rows.first.flatMap { NVDeepLink.noteURL($0.note.id) } ?? NVDeepLink.feed.url)
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NV.purple)
            Text("On this day")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
    }

    private func small(_ row: (years: Int, note: NVOnThisDaySnapshot.Note)) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(NVOnThisDaySnapshot.yearsText(row.years))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NV.purple)
            Text(row.note.text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(4)
            Spacer(minLength: 0)
            if rows.count > 1 {
                Text("+\(rows.count - 1) more")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    /// Up to three rows, each its own link; the year shows once above its notes.
    private var medium: some View {
        let shown = Array(rows.prefix(3).enumerated())
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(shown, id: \.element.note.id) { i, row in
                if i == 0 || shown[i - 1].element.years != row.years {
                    Text(NVOnThisDaySnapshot.yearsText(row.years))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NV.purple)
                }
                Link(destination: NVDeepLink.noteURL(row.note.id) ?? NVDeepLink.feed.url) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.note.text)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.note.createdAt, style: .time)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct OnThisDayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "OnThisDay", provider: OnThisDayProvider()) { entry in
            OnThisDayView(entry: entry)
                .containerBackground(NV.background, for: .widget)
        }
        .configurationDisplayName("On this day")
        .description("Your own notes from this date one and two years ago.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

extension NVWidgetSnapshot {
    /// The gallery's picture of the widget before the app has read a day.
    static let onThisDayPreview: NVWidgetSnapshot = {
        let now = Date()
        var s = NVWidgetSnapshot.preview
        let cal = Calendar.current
        let ago = { (y: Int, h: Int) in
            cal.date(byAdding: .year, value: -y, to: cal.startOfDay(for: now))!.addingTimeInterval(TimeInterval(h * 3_600))
        }
        s.onThisDay = NVOnThisDaySnapshot(dayStart: cal.startOfDay(for: now), years: [
            .init(years: 1, notes: [
                .init(id: String(repeating: "1", count: 64), text: "First frost of the year. Coffee in hand, nowhere to be.", createdAt: ago(1, 8)),
                .init(id: String(repeating: "2", count: 64), text: "Shipped the new vault sync tonight.", createdAt: ago(1, 19)),
            ]),
            .init(years: 2, notes: [
                .init(id: String(repeating: "3", count: 64), text: "Two years of running my own relay.", createdAt: ago(2, 14)),
            ]),
        ])
        return s
    }()
}
