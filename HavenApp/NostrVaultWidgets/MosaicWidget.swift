import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Mosaic
//
// Your Blossom media as a grid, with the Media tab's filter chips across the
// top and its Magic Paste on the right.
//
// The images are the whole point of this widget, and getting them on screen is
// the part that is not obvious: a widget draws in a single static pass, so
// `AsyncImage` here renders its placeholder and never resolves. Tiles arrive as
// bytes instead — shrunk by the app for anything on this device (NVThumbnails),
// fetched by the timeline provider for anything remote (NVTileFetcher).

enum MosaicStyle: String, AppEnum {
    case grid, featured

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Layout" }
    static var caseDisplayRepresentations: [MosaicStyle: DisplayRepresentation] = [
        .grid: "Even grid",
        .featured: "One large, rest small",
    ]
}

struct MosaicIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Mosaic"
    static var description = IntentDescription("Your Blossom media, live on the Home Screen.")

    @Parameter(title: "Layout", default: .grid)
    var style: MosaicStyle

    @Parameter(title: "Rounded tiles", default: true)
    var rounded: Bool
}

/// Sets the filter chip. Runs in the widget process, writes the choice to the
/// shared prefs item, and asks WidgetKit for a new timeline so the grid redraws
/// against the new filter.
struct MosaicFilterIntent: AppIntent {
    static var title: LocalizedStringResource = "Filter media"

    @Parameter(title: "Filter")
    var filter: String

    init() {}
    init(filter: NVMediaFilter) { self.filter = filter.rawValue }

    func perform() async throws -> some IntentResult {
        let choice = NVMediaFilter(rawValue: filter) ?? .all
        NVWidgetPrefsStore.save(NVWidgetPrefs(mosaicFilter: choice))
        WidgetCenter.shared.reloadTimelines(ofKind: "Mosaic")
        return .result()
    }
}

struct MosaicEntry: TimelineEntry {
    let date: Date
    let snapshot: NVWidgetSnapshot
    let images: [String: Data]
    let filter: NVMediaFilter
    let config: MosaicIntent
}

struct MosaicProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MosaicEntry {
        MosaicEntry(date: Date(), snapshot: .preview, images: [:], filter: .all, config: MosaicIntent())
    }

    func snapshot(for configuration: MosaicIntent, in context: Context) async -> MosaicEntry {
        await entry(for: configuration, fallback: .preview)
    }

    func timeline(for configuration: MosaicIntent, in context: Context) async -> Timeline<MosaicEntry> {
        let entry = await entry(for: configuration, fallback: .empty)
        // Media changes far less often than a feed, and every refresh costs a
        // batch of downloads, so this one runs on the hour.
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60)))
    }

    private func entry(for configuration: MosaicIntent, fallback: NVWidgetSnapshot) async -> MosaicEntry {
        let snapshot = NVSharedStore.load() ?? fallback
        let filter = NVWidgetPrefsStore.load().mosaicFilter
        let tiles = snapshot.media.filter { filter.accepts($0.kind) }

        // Local blobs came across as bytes; anything left is remote and is the
        // only thing worth spending network time on.
        var images = NVThumbnailStore.load()?.images ?? [:]
        let missing = tiles.filter { images[$0.id] == nil }
        if !missing.isEmpty {
            images.merge(await NVTileFetcher.fetch(missing)) { existing, _ in existing }
        }

        return MosaicEntry(date: Date(), snapshot: snapshot, images: images,
                           filter: filter, config: configuration)
    }
}

struct MosaicView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MosaicEntry

    private var tiles: [NVWidgetSnapshot.MediaTile] {
        Array(entry.snapshot.media.filter { entry.filter.accepts($0.kind) }.prefix(capacity))
    }

    /// Tile counts sized so each cell stays large enough to read as an image
    /// rather than a swatch.
    private var capacity: Int {
        switch family {
        case .systemSmall: return entry.config.style == .featured ? 1 : 4
        case .systemMedium: return entry.config.style == .featured ? 5 : 8
        case .systemLarge: return entry.config.style == .featured ? 7 : 9
        case .systemExtraLarge: return entry.config.style == .featured ? 9 : 18
        default: return 4
        }
    }

    private var columns: Int {
        switch family {
        case .systemSmall: return 2
        case .systemMedium: return 4
        case .systemLarge: return 3
        case .systemExtraLarge: return 6
        default: return 2
        }
    }

    /// Small is too narrow for four chips and a wand; it stays a pure grid and
    /// inherits whatever filter you set on a bigger one.
    private var showsChrome: Bool { family != .systemSmall }

    private var corner: CGFloat { entry.config.rounded ? 8 : 0 }

    var body: some View {
        VStack(spacing: 6) {
            if showsChrome { chrome }
            grid
        }
    }

    @ViewBuilder
    private var grid: some View {
        if tiles.isEmpty {
            NVEmptyState(icon: "photo.on.rectangle", message: emptyMessage)
        } else if entry.config.style == .featured, let hero = tiles.first {
            VStack(spacing: 4) {
                Link(destination: NVDeepLink.media.url) {
                    Tile(tile: hero, data: entry.images[hero.id], corner: corner)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if tiles.count > 1, family != .systemSmall {
                    HStack(spacing: 4) {
                        ForEach(tiles.dropFirst()) { tile in
                            Link(destination: NVDeepLink.media.url) {
                                // Equal shares of the row rather than squares:
                                // six 44pt squares do not fit across a large
                                // widget, and one that does not fit is one that
                                // pushes the rest off the edge.
                                Tile(tile: tile, data: entry.images[tile.id], corner: corner)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(height: 44)
                }
            }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                ForEach(tiles) { tile in
                    Link(destination: NVDeepLink.media.url) {
                        Tile(tile: tile, data: entry.images[tile.id], corner: corner)
                            .aspectRatio(1, contentMode: .fill)
                    }
                }
            }
        }
    }

    /// "Nothing here" and "nothing matching this chip" are different problems
    /// and want different sentences — one is a prompt to upload, the other is a
    /// prompt to change the filter.
    private var emptyMessage: String {
        if !entry.snapshot.hasEverRun { return "Open Nostr Vault to load your media" }
        if entry.filter != .all && !entry.snapshot.media.isEmpty {
            return "No \(entry.filter.label.lowercased()) yet"
        }
        return "No media on your relay yet"
    }

    /// The Media tab's filter row, plus its Magic Paste, on the widget face.
    private var chrome: some View {
        HStack(spacing: 4) {
            ForEach(NVMediaFilter.allCases, id: \.self) { option in
                Button(intent: MosaicFilterIntent(filter: option)) {
                    Text(option.label)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(option == entry.filter ? Color.white : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(option == entry.filter ? NV.purple.opacity(0.85)
                                                                  : Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            // Magic Paste cannot happen inside the widget: iOS will not hand an
            // extension the clipboard without a prompt, and a widget has no
            // surface to show one on. This opens the Media tab with the app's
            // own paste already running, which is the same single tap.
            Link(destination: NVDeepLink.mediaPaste.url) {
                Image("MagicPaste")
                    .resizable()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(NV.purple)
                    .padding(5)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
        }
    }
}

private struct Tile: View {
    let tile: NVWidgetSnapshot.MediaTile
    let data: Data?
    let corner: CGFloat

    var body: some View {
        // `Color.clear` is the load-bearing part, not decoration. A
        // `scaledToFill` image reports back a size *larger* than the one it was
        // offered, along whichever edge the photo is long, and a ZStack adopts
        // that oversize. The cell then overflows its grid column, the grid
        // widens the widget's content, and the filter chips and wand get pushed
        // off the face. Sizing off an empty colour and hanging the picture in an
        // overlay pins the layout to the cell; only the drawing overflows, and
        // `clipped()` takes care of that.
        Color.clear
            .overlay {
                if let data, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    // No bytes: a blob still on a host we could not reach, or one
                    // trimmed by the handoff budget. A tinted tile keyed to the id
                    // keeps the grid reading as media rather than as a failure.
                    LinearGradient(colors: [hue.opacity(0.65), hue.opacity(0.25)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .overlay {
                if tile.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 3)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .contentShape(Rectangle())
    }

    private var hue: Color {
        Color(hue: Double(abs(tile.id.hashValue) % 360) / 360, saturation: 0.5, brightness: 0.8)
    }
}

struct MosaicWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Mosaic", intent: MosaicIntent.self, provider: MosaicProvider()) { entry in
            MosaicView(entry: entry)
                .containerBackground(NV.background, for: .widget)
        }
        .configurationDisplayName("Mosaic")
        .description("Your Blossom media as a living grid.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
