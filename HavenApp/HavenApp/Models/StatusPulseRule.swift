import Foundation

/// When the Relay page's status dot pulses: only while the vault is starting.
///
/// It used to pulse for as long as the relay ran. A repeat-forever animation
/// there redraws the whole Mac window every frame (about 45% CPU against 7%,
/// Tron 2026-11-11), and it kept going after the window closed, because the
/// window's views stay alive behind the menu bar icon. A running vault now
/// shows a steady dot; the colour and the ONLINE label still say it is live.
enum StatusPulseRule {
    static func pulses(isRunning: Bool, isBooting: Bool, reduceMotion: Bool) -> Bool {
        isBooting && !reduceMotion
    }
}
