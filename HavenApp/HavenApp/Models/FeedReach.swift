import Foundation

/// Settings › Feeds › Reach: how far each feed reaches (Logen 2026-11-18).
/// "Your web" (`WebGate.Reach.web`) or "Your web + a few one hop out"
/// (`.webAndHop3`, rationed by `WebGate.capHop3`). Underrated reaches one hop
/// out by default; every other feed keeps to your web. Following and Catch Up
/// are your follows by definition and have no setting.
enum FeedReach {
    /// The feeds with a Reach setting, in Settings order.
    static let modes: [FeedMode] = [.discovery, .global, .popular, .underrated, .media]

    static func defaultReach(for mode: FeedMode) -> WebGate.Reach {
        mode == .underrated ? .webAndHop3 : .web
    }

    /// `settings` maps a mode's raw value to a reach's raw value; anything
    /// missing, unknown or `everyone` (never a setting) is the default.
    static func reach(for mode: FeedMode, settings: [String: String]) -> WebGate.Reach {
        guard modes.contains(mode) else { return .web }
        if let raw = settings[mode.rawValue], let reach = WebGate.Reach(rawValue: raw), reach != .everyone {
            return reach
        }
        return defaultReach(for: mode)
    }

    /// `settings` with `mode` set to `reach`; the default is stored as absent.
    static func setting(_ reach: WebGate.Reach, for mode: FeedMode, in settings: [String: String]) -> [String: String] {
        var out = settings
        out[mode.rawValue] = reach == defaultReach(for: mode) ? nil : reach.rawValue
        return out
    }

    static func label(_ reach: WebGate.Reach) -> String {
        switch reach {
        case .web: return "Your web"
        case .webAndHop3: return "Your web + a few one hop out"
        case .everyone: return "Everyone"
        }
    }
}
