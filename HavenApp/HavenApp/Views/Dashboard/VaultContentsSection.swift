import SwiftUI

/// The dashboard's "In your vault": how much room the vault takes, what it
/// holds by kind, its media files and its cache, in one card. Every row with
/// a breakdown opens it in place; nothing leaves the dashboard.
///
/// Replaces the four tiles that closed the dashboard to open other screens,
/// the Storage card with its three levels of sheets, and Advanced › Relay
/// details › What's stored.
struct VaultContentsSection: View {
    @ObservedObject var model: VaultContentsModel
    @EnvironmentObject var relayManager: RelayProcessManager
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var statsService: StatsService

    @State private var expanded: Set<String> = []
    @State private var confirmingClearCache = false
    @State private var isClearingCache = false

    var body: some View {
        DashboardSection(title: "In your vault", detail: headerDetail) {
            storageBar
            DashboardDivider()
            eventRows
            DashboardDivider()
            mediaRow
            DashboardDivider()
            cacheRow
        }
        .animation(Motion.toggle, value: expanded)
        .alert("Clear the cache?", isPresented: $confirmingClearCache) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive, action: clearCache)
        } message: {
            Text("Removes the copies of other people's images and videos kept for quick loading. Your own media stays. They download again when needed.")
        }
    }

    private var headerDetail: String {
        let size = Self.size(statsService.storageSize)
        guard let total = model.contents?.total else { return size }
        return "\(total.formatted()) \(total == 1 ? "event" : "events") · \(size)"
    }

    // MARK: Storage

    private var storageParts: [(title: String, size: Int64, color: Color)] {
        let media = statsService.blossomSize
        let cache = statsService.cacheSize + statsService.thumbnailSize
        let data = max(0, statsService.storageSize - media - cache)
        return [("Notes and data", data, .havenPurple), ("Media", media, .blue), ("Cache", cache, .gray)]
    }

    private var storageBar: some View {
        let parts = storageParts
        let total = max(1, parts.reduce(0) { $0 + $1.size })
        return VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.title) { part in
                        if part.size > 0 {
                            Rectangle()
                                .fill(part.color)
                                .frame(width: max(3, (geo.size.width - 4) * CGFloat(part.size) / CGFloat(total)))
                        }
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
                .background(Color.platformControlBackground)
                .clipShape(Capsule())
            }
            .frame(height: 10)

            HStack(alignment: .top, spacing: 8) {
                ForEach(parts, id: \.title) { part in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Circle().fill(part.color).frame(width: 7, height: 7)
                            Text(part.title).foregroundColor(.primary)
                        }
                        Text(Self.size(part.size))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .padding(.leading, 12)
                    }
                    .font(.appSystem(size: 12))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Storage")
        .accessibilityValue(parts.map { "\($0.title) \(Self.size($0.size))" }.joined(separator: ", "))
    }

    // MARK: Events

    @ViewBuilder
    private var eventRows: some View {
        if let contents = model.contents {
            let rows = contents.groupRows
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { DashboardDivider() }
                ExpandingRow(
                    icon: row.group.icon,
                    title: row.group.title,
                    value: row.count.formatted(),
                    detail: row.yours.map { "\($0.formatted()) yours" },
                    isExpanded: binding(row.id),
                    canExpand: row.kinds.count > 1
                ) {
                    ForEach(row.kinds) { kind in
                        BreakdownLine(title: kind.title, value: kind.count.formatted())
                    }
                }
            }
            if model.countFailed || model.isCounting || model.publicOnly {
                DashboardDivider()
                statusLine
            }
        } else {
            statusLine
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if model.isCounting { ProgressView().controlSize(.small) }
            Text(model.isCounting ? "Counting…"
                 : !relayManager.isRunning ? "Start your vault to count what's in it."
                 : model.countFailed ? "Couldn't count. Pull down to try again."
                 : RelayCountSession.publicOnlyNote)
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Media and cache

    private var mediaRow: some View {
        let media = model.media
        return ExpandingRow(
            icon: "photo.on.rectangle",
            title: "Media files",
            value: media.map { $0.count.formatted() } ?? "—",
            detail: media.map { Self.size($0.size) },
            isExpanded: binding("media"),
            canExpand: (media?.count ?? 0) > 0
        ) {
            ForEach(media?.buckets.filter { $0.count > 0 } ?? []) { bucket in
                BreakdownLine(title: bucket.title, value: "\(bucket.count.formatted()) · \(Self.size(bucket.size))")
            }
        }
    }

    private var cacheRow: some View {
        let cache = model.cache
        let lines: [(String, Int, Int64)] = cache.map {
            [("Images", $0.imageCount, $0.imageSize), ("Videos", $0.videoCount, $0.videoSize),
             ("Video thumbnails", $0.thumbnailCount, $0.thumbnailSize), ("Other", $0.otherCount, $0.otherSize)]
        }?.filter { $0.1 > 0 } ?? []
        return ExpandingRow(
            icon: "photo.stack",
            title: "Cache",
            value: Self.size(statsService.cacheSize + statsService.thumbnailSize),
            detail: "Other people's media, kept for quick loading",
            isExpanded: binding("cache"),
            canExpand: true
        ) {
            ForEach(lines, id: \.0) { line in
                BreakdownLine(title: line.0, value: "\(line.1.formatted()) · \(Self.size(line.2))")
            }
            HStack {
                Spacer()
                RowButton(title: "Clear cache", isLoading: isClearingCache) { confirmingClearCache = true }
                    .disabled(isClearingCache || lines.isEmpty)
            }
            .padding(.top, 4)
        }
    }

    private func clearCache() {
        isClearingCache = true
        let result = MediaCacheService.shared.clearCache()
        let freed = ByteCountFormatter.string(fromByteCount: result.bytesFreed, countStyle: .file)
        if result.filesFailed == 0 {
            ActionToastManager.shared.show(icon: "trash.fill", message: "Cleared \(freed) of temporary copies", color: Color.havenVerified)
        } else {
            ErrorNotificationManager.shared.show("Cleared \(freed), but \(result.filesFailed) files could not be removed", icon: "exclamationmark.triangle.fill", style: .warning)
        }
        statsService.refreshStats()
        Task {
            await model.loadFiles(relayManager: relayManager, configService: configService, statsService: statsService)
            isClearingCache = false
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    /// "None" rather than ByteCountFormatter's "Zero KB".
    static func size(_ bytes: Int64) -> String {
        bytes <= 0 ? "None" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A row that opens its breakdown underneath it.
private struct ExpandingRow<Content: View>: View {
    let icon: String
    let title: String
    let value: String
    let detail: String?
    @Binding var isExpanded: Bool
    let canExpand: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if canExpand {
                Button { isExpanded.toggle() } label: { label }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Text(accessibilityValue))
                    .accessibilityHint(Text(isExpanded ? "Hides the breakdown" : "Shows the breakdown"))
            } else {
                label
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(Text(accessibilityValue))
            }

            if isExpanded && canExpand {
                VStack(alignment: .leading, spacing: 6) { content }
                    .padding(.leading, 56)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
    }

    private var accessibilityValue: String {
        [value, detail].compactMap { $0 }.joined(separator: ", ")
    }

    private var label: some View {
        HStack(spacing: 12) {
            RowIcon(icon: icon, state: .info)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                if let detail {
                    Text(detail)
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(.appSystem(size: 15))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.appSystem(size: 12, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.6))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .opacity(canExpand ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// One line of a breakdown: a name and its number.
private struct BreakdownLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundColor(.primary)
            Spacer(minLength: 8)
            Text(value).foregroundColor(.secondary).monospacedDigit()
        }
        .font(.appSystem(size: 13))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}
