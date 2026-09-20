import SwiftUI
import WidgetKit

// MARK: - Shared widget chrome
//
// The app's palette is not available here: Color.havenPurple and friends live
// in Views/, which the extension deliberately does not compile. These are the
// same values, restated for a process that has to stay small.

enum NV {
    static let purple = Color(red: 0.51, green: 0.35, blue: 0.94)
    static let orange = Color(red: 0.98, green: 0.55, blue: 0.14)
    static let ink = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let inkSoft = Color(red: 0.11, green: 0.11, blue: 0.14)

    /// Widgets sit on a user-chosen wallpaper, so they need their own ground.
    /// A flat fill reads as a hole punched in the Home Screen; a slight
    /// vertical lift reads as an object sitting on it.
    static var background: LinearGradient {
        LinearGradient(colors: [inkSoft, ink], startPoint: .top, endPoint: .bottom)
    }

    static func compactCount(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000).replacingOccurrences(of: ".0k", with: "k")
        default: return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
    }

    static func compactBytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        return f.string(fromByteCount: b)
    }

    /// "3m", "4h", "2d" -- widgets never have room for a real date.
    static func shortAge(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "now"
        case ..<3_600: return "\(s / 60)m"
        case ..<86_400: return "\(s / 3_600)h"
        default: return "\(s / 86_400)d"
        }
    }
}

// MARK: - Staleness

extension NVWidgetSnapshot {
    /// The app has not written in a while, so what we are holding is history.
    /// Widgets that show live numbers say so rather than lying quietly.
    var isStale: Bool { Date().timeIntervalSince(generatedAt) > 3_600 }
    var hasEverRun: Bool { generatedAt != .distantPast }
}

/// Shown when the app has never run, so there is genuinely nothing to draw.
/// Distinct from stale data, and worth distinguishing: one is "open the app
/// once", the other is "the app is not refreshing".
struct NVEmptyState: View {
    var icon: String
    var message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(NV.purple.opacity(0.8))
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(8)
    }
}

// MARK: - Preview data

extension NVWidgetSnapshot {
    /// Used for the widget gallery and Xcode previews. WidgetKit renders the
    /// gallery before the user has granted anything, so this must look like a
    /// healthy vault rather than an empty one.
    static let preview: NVWidgetSnapshot = {
        let now = Date()
        return NVWidgetSnapshot(
            generatedAt: now,
            relay: .init(isRunning: true, eventCount: 48_213, storageBytes: 2_143_289_344,
                         connectionCount: 6, uptimeSeconds: 96 * 3_600),
            feed: [
                .init(id: "1", authorName: "fiatjaf", authorPictureURL: nil,
                      text: "the relay is the client", createdAt: now.addingTimeInterval(-360), imageURL: nil),
                .init(id: "2", authorName: "Vitor", authorPictureURL: nil,
                      text: "Outbox model finally clicking for people.", createdAt: now.addingTimeInterval(-2_700), imageURL: nil),
                .init(id: "3", authorName: "hodlbod", authorPictureURL: nil,
                      text: "Signed events over a relay you own beats an API key.", createdAt: now.addingTimeInterval(-9_000), imageURL: nil),
            ],
            mentions: [
                .init(id: "4", authorName: "jack", authorPictureURL: nil,
                      text: "nice work on the vault", createdAt: now.addingTimeInterval(-1_800), imageURL: nil),
            ],
            wallet: .init(lightningSats: 8_600, zapsReceived24h: 12, btcPriceUSD: 98_400),
            // The gallery renders this before the app has ever published, and
            // an empty grid there reads as a broken widget. These have no bytes
            // behind them, so they draw as the tinted tiles Mosaic falls back to.
            media: (0..<18).map { i in
                .init(id: "preview-\(i)",
                      url: URL(string: "https://example.invalid/\(i)")!,
                      kind: i % 6 == 0 ? .video : .image)
            },
            unreadDMCount: 3
        )
    }()
}
