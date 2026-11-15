import SwiftUI

/// The sky behind the globe: deep space at night (Dark), a late-morning sky
/// by day (Light): pale blue overhead into a warm haze at the bottom.
struct GlobeSpace: View {
    static let edge = Color.black
    /// Day: the top of the sky, for a navigation bar drawn over it.
    static let dayEdge = Color(hex: 0x9CC8EE)
    static let daySky = [Color(hex: 0x9CC8EE), Color(hex: 0xCFE3F4), Color(hex: 0xF3E6D3)]

    @Environment(\.globeDay) private var day

    var body: some View {
        Group {
            if day {
                LinearGradient(colors: Self.daySky, startPoint: .top, endPoint: .bottom)
            } else {
                RadialGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.13), Self.edge],
                               center: .center, startRadius: 40, endRadius: 900)
            }
        }
        .ignoresSafeArea()
    }
}

/// What the globe draws its stars, threads and names in. Night is the
/// original set for deep space; day is darker so it reads on the sky.
struct GlobeInk {
    let ring: Color
    let haze: Color
    /// Warm amber for the threads, lighter than the glow behind them.
    let thread: Color
    /// Mutual stars, live-arc stars, the core's ring for someone else.
    let star: Color
    let label: Color
    /// The author's face ring.
    let author: Color
    /// The bright core of a zap bolt.
    let boltCore: Color

    static let night = GlobeInk(ring: Color(red: 0.72, green: 0.82, blue: 1),
                                haze: Color(red: 0.62, green: 0.55, blue: 0.9),
                                thread: Color(red: 1, green: 0.66, blue: 0.3),
                                star: .white, label: .white, author: .yellow, boltCore: .white)
    static let day = GlobeInk(ring: Color(hex: 0x2F5FA8),
                              haze: Color(hex: 0x6A5CA8),
                              thread: Color(hex: 0xC2571A),
                              star: Color(hex: 0x1E2B45), label: Color(hex: 0x1E2B45),
                              author: Color(hex: 0xC98A00), boltCore: Color(hex: 0xA86A00))
}

private struct GlobeDayKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the app is in Light: the globe draws the day sky. Set by the
    /// globe's screen from the app's own scheme, because the globe's chrome
    /// keeps dark glass in both.
    var globeDay: Bool {
        get { self[GlobeDayKey.self] }
        set { self[GlobeDayKey.self] = newValue }
    }
}
