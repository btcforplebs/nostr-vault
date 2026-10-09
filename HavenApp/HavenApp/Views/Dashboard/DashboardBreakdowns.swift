import SwiftUI
import UniformTypeIdentifiers

struct EventKindBreakdownView: View {
    @EnvironmentObject var statsService: StatsService
    @Environment(\.dismiss) private var dismiss

    @State private var counts: [Int: Int] = [:]
    @State private var isLoading = true

    private static let kindNames: [Int: String] = [
        0: "Profile Metadata",
        1: "Short Notes",
        3: "Contacts",
        4: "Encrypted DMs (legacy)",
        5: "Event Deletions",
        6: "Reposts",
        7: "Reactions",
        8: "Badge Awards",
        9: "Chat Messages",
        16: "Generic Reposts",
        1059: "Gift Wraps (DMs)",
        1063: "File Metadata",
        1311: "Live Chat",
        1808: "Audio Tracks",
        9734: "Zap Requests",
        9735: "Zap Receipts",
        10000: "Mute Lists",
        10001: "Pinned Notes",
        10002: "Relay Lists",
        10003: "Bookmarks",
        10005: "Public Chats",
        10006: "Blocked Relays",
        10015: "Interest Lists",
        10030: "Emoji Lists",
        30000: "People Lists",
        30001: "Generic Lists",
        30002: "Relay Sets",
        30008: "Profile Badges",
        30009: "Badge Definitions",
        30023: "Long-form Articles",
        30024: "Long-form Drafts",
        30030: "Emoji Sets",
        30078: "App Data"
    ]

    private var total: Int { counts[-1] ?? 0 }

    private var sortedKinds: [(kind: Int, count: Int)] {
        counts.filter { $0.key != -1 }
              .sorted { $0.value > $1.value }
              .map { (kind: $0.key, count: $0.value) }
    }

    private var knownTotal: Int {
        sortedKinds.reduce(0) { $0 + $1.count }
    }

    private var otherCount: Int {
        max(0, total - knownTotal)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.platformWindowBackground.ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        Text("Counting events by kind…")
                            .font(.appSystem(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(total)")
                                        .font(.appSystem(size: 28, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                    Text("Total Events")
                                        .font(.appSystem(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(16)
                            .background(Color.havenPurple.opacity(0.1))
                            .cornerRadius(12)
                            .padding(.horizontal)
                            .padding(.top, 12)

                            VStack(spacing: 1) {
                                ForEach(sortedKinds, id: \.kind) { item in
                                    KindRow(
                                        kind: item.kind,
                                        name: Self.kindNames[item.kind] ?? "Kind \(item.kind)",
                                        count: item.count,
                                        total: total
                                    )
                                }

                                if otherCount > 0 {
                                    KindRow(
                                        kind: -2,
                                        name: "Other (unqueried kinds)",
                                        count: otherCount,
                                        total: total
                                    )
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .navigationTitle("Event Breakdown")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { Task { await reload() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        #endif
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        counts = await statsService.fetchCountsByKind()
        isLoading = false
    }
}

struct BlossomBreakdownView: View {
    @EnvironmentObject var statsService: StatsService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss

    @State private var blobs: [BlobDescriptor] = []
    @State private var isLoading = true

    private var totalCount: Int { blobs.count }
    private var totalSize: Int { blobs.compactMap(\.size).reduce(0, +) }

    private struct TypeBucket {
        let label: String
        let icon: String
        let color: Color
        let count: Int
        let size: Int
    }

    private var buckets: [TypeBucket] {
        var images = (count: 0, size: 0), videos = (count: 0, size: 0), audio = (count: 0, size: 0), other = (count: 0, size: 0)
        for blob in blobs {
            let t = blob.type ?? ""
            let s = blob.size ?? 0
            if t.hasPrefix("image/") { images.count += 1; images.size += s }
            else if t.hasPrefix("video/") { videos.count += 1; videos.size += s }
            else if t.hasPrefix("audio/") { audio.count += 1; audio.size += s }
            else { other.count += 1; other.size += s }
        }
        return [
            TypeBucket(label: "Images", icon: "photo.fill", color: .blue, count: images.count, size: images.size),
            TypeBucket(label: "Videos", icon: "video.fill", color: .orange, count: videos.count, size: videos.size),
            TypeBucket(label: "Audio", icon: "waveform", color: .purple, count: audio.count, size: audio.size),
            TypeBucket(label: "Other", icon: "doc.fill", color: .secondary, count: other.count, size: other.size),
        ].filter { $0.count > 0 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.platformWindowBackground.ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        Text("Counting blobs…")
                            .font(.appSystem(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(totalCount)")
                                        .font(.appSystem(size: 28, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                    Text("Total Blobs")
                                        .font(.appSystem(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file))
                                        .font(.appSystem(size: 28, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                    Text("Total Size")
                                        .font(.appSystem(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(16)
                            .background(Color.havenPurple.opacity(0.1))
                            .cornerRadius(12)
                            .padding(.horizontal)
                            .padding(.top, 12)

                            VStack(spacing: 1) {
                                ForEach(buckets, id: \.label) { bucket in
                                    BlobTypeRow(
                                        label: bucket.label,
                                        icon: bucket.icon,
                                        color: bucket.color,
                                        count: bucket.count,
                                        size: bucket.size,
                                        total: totalSize
                                    )
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .navigationTitle("Blob Breakdown")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { Task { await reload() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        #endif
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        let pubkey = configService.activeAccountHexPubkey
        blobs = await statsService.fetchBlobList(for: pubkey)
        isLoading = false
    }
}

struct MediaCacheBreakdownView: View {
    @EnvironmentObject var statsService: StatsService
    @Environment(\.dismiss) private var dismiss

    @State private var breakdown: StatsService.CacheBreakdown?
    @State private var isLoading = true
    @State private var showingClearConfirmation = false
    @State private var isClearing = false

    private var totalSize: Int64 {
        guard let b = breakdown else { return 0 }
        return b.imageSize + b.videoSize + b.thumbnailSize + b.otherSize
    }

    private var totalCount: Int {
        guard let b = breakdown else { return 0 }
        return b.imageCount + b.videoCount + b.thumbnailCount + b.otherCount
    }

    private struct TypeBucket {
        let label: String
        let icon: String
        let color: Color
        let count: Int
        let size: Int64
    }

    private var buckets: [TypeBucket] {
        guard let b = breakdown else { return [] }
        return [
            TypeBucket(label: "Cached Images", icon: "photo.fill", color: .blue, count: b.imageCount, size: b.imageSize),
            TypeBucket(label: "Cached Videos", icon: "video.fill", color: .orange, count: b.videoCount, size: b.videoSize),
            TypeBucket(label: "Video Thumbnails", icon: "rectangle.grid.2x2.fill", color: .purple, count: b.thumbnailCount, size: b.thumbnailSize),
            TypeBucket(label: "Other", icon: "doc.fill", color: .secondary, count: b.otherCount, size: b.otherSize),
        ].filter { $0.count > 0 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.platformWindowBackground.ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.havenPurple)
                        Text("Scanning cache\u{2026}")
                            .font(.appSystem(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(totalCount)")
                                        .font(.appSystem(size: 28, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                    Text("Cached Files")
                                        .font(.appSystem(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                                        .font(.appSystem(size: 28, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                    Text("Total Size")
                                        .font(.appSystem(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(16)
                            .background(Color.havenPurple.opacity(0.1))
                            .cornerRadius(12)
                            .padding(.horizontal)
                            .padding(.top, 12)

                            VStack(spacing: 1) {
                                ForEach(buckets, id: \.label) { bucket in
                                    BlobTypeRow(
                                        label: bucket.label,
                                        icon: bucket.icon,
                                        color: bucket.color,
                                        count: bucket.count,
                                        size: Int(bucket.size),
                                        total: Int(totalSize)
                                    )
                                }
                            }
                            .padding(.horizontal)

                            // Cache lifetime info
                            if let b = breakdown, totalCount > 0 {
                                let ttlDays = ConfigService.shared.config.cacheTTLDays
                                VStack(spacing: 6) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "clock.fill")
                                            .font(.appSystem(size: 12))
                                            .foregroundColor(.secondary)
                                        Text("TTL: \(ttlDays > 0 ? "\(ttlDays) day\(ttlDays == 1 ? "" : "s")" : "Never expires")")
                                            .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    if let oldest = b.oldestFile {
                                        HStack(spacing: 8) {
                                            Image(systemName: "calendar")
                                                .font(.appSystem(size: 12))
                                                .foregroundColor(.secondary)
                                            Text("Oldest: \(Self.relativeDate(oldest))")
                                                .font(.appSystem(size: 12, design: .monospaced))
                                                .foregroundColor(.secondary)
                                            Spacer()
                                            if let newest = b.newestFile {
                                                Text("Newest: \(Self.relativeDate(newest))")
                                                    .font(.appSystem(size: 12, design: .monospaced))
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }
                                }
                                .padding(12)
                                .background(Color.platformCardBackground)
                                .cornerRadius(8)
                                .padding(.horizontal)
                                .padding(.top, 4)
                            }

                            Button(action: { showingClearConfirmation = true }) {
                                HStack {
                                    if isClearing {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "trash")
                                    }
                                    Text("Clear Cache")
                                }
                                .font(.appSystem(size: 14, weight: .semibold))
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.red.opacity(0.3), lineWidth: 1)
                                )
                            }
                            .disabled(isClearing || totalCount == 0)
                            .padding(.horizontal)
                            .padding(.top, 16)
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
            .navigationTitle("Cache Breakdown")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { Task { await reload() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .alert("Clear Media Cache?", isPresented: $showingClearConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    isClearing = true
                    let result = MediaCacheService.shared.clearCache()
                    let freed = ByteCountFormatter.string(fromByteCount: result.bytesFreed, countStyle: .file)
                    if result.filesFailed == 0 {
                        ActionToastManager.shared.show(icon: "trash.fill", message: "Cleared \(freed) of temporary copies", color: Color.havenVerified)
                    } else {
                        ErrorNotificationManager.shared.show("Cleared \(freed), but \(result.filesFailed) files could not be removed", icon: "exclamationmark.triangle.fill", style: .warning)
                    }
                    statsService.refreshStats()
                    Task {
                        await reload()
                        isClearing = false
                    }
                }
            } message: {
                Text("This will remove all cached images, videos, and thumbnails. Blossom media will not be affected. Files will be re-downloaded as needed.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        #endif
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        let service = statsService
        let relayDir = ConfigService.shared.relayDataDir
        breakdown = await Task.detached(priority: .userInitiated) {
            return service.calculateCacheBreakdown(relayDir: relayDir)
        }.value
        isLoading = false
    }

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct StorageBreakdownView: View {
    @EnvironmentObject var statsService: StatsService
    @EnvironmentObject var configService: ConfigService
    @Environment(\.dismiss) private var dismiss

    @State private var showingBlossomBreakdown = false
    @State private var showingCacheBreakdown = false

    /// Which detail view a bucket opens, if any. The dashboard used to give
    /// Blossom and the media cache their own stat cards; they are reachable
    /// from here now, one level down from the total they are part of.
    private enum StorageDetail {
        case blossom
        case cache
    }

    private struct StorageBucket: Identifiable {
        let id = UUID()
        let label: String
        let icon: String
        let color: Color
        let size: Int64
        var detail: StorageDetail? = nil
    }

    private var buckets: [StorageBucket] {
        let dbSize = max(0, statsService.storageSize - statsService.blossomSize - statsService.cacheSize - statsService.thumbnailSize)
        return [
            StorageBucket(label: "Database", icon: "cylinder.fill", color: .blue, size: dbSize),
            StorageBucket(label: "Blossom Media", icon: "camera.macro", color: .green, size: statsService.blossomSize, detail: .blossom),
            StorageBucket(label: "Media Cache", icon: "photo.stack.fill", color: .orange, size: statsService.cacheSize + statsService.thumbnailSize, detail: .cache),
        ].filter { $0.size > 0 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.platformWindowBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ByteCountFormatter.string(fromByteCount: statsService.storageSize, countStyle: .file))
                                    .font(.appSystem(size: 28, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                Text("Total Storage Used")
                                    .font(.appSystem(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(16)
                        .background(Color.havenPurple.opacity(0.1))
                        .cornerRadius(12)
                        .padding(.horizontal)
                        .padding(.top, 12)

                        VStack(spacing: 1) {
                            ForEach(buckets) { bucket in
                                StorageRow(
                                    label: bucket.label,
                                    icon: bucket.icon,
                                    color: bucket.color,
                                    size: bucket.size,
                                    total: statsService.storageSize,
                                    action: bucket.detail.map { detail in
                                        {
                                            switch detail {
                                            case .blossom: showingBlossomBreakdown = true
                                            case .cache: showingCacheBreakdown = true
                                            }
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Storage Breakdown")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { statsService.refreshStats() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        #endif
        .sheet(isPresented: $showingBlossomBreakdown) {
            BlossomBreakdownView()
                .environmentObject(statsService)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showingCacheBreakdown) {
            MediaCacheBreakdownView()
                .environmentObject(statsService)
        }
    }
}

