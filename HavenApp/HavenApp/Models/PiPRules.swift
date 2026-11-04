import Foundation

/// Picture-in-picture rules shared by the players (PiPManager; RESEARCH/NV_PIP_PLAN.md lane B).
enum PiPRules {
    /// Closing PiP stops our own video and hands audio back. The mini player's
    /// live stream (shared playback) keeps playing: its sound is the mini player's.
    static func pausesWhenClosed(sharedPlayback: Bool) -> Bool { !sharedPlayback }

    /// The PiP button shows when the device can do PiP at all, so it doesn't
    /// pop in late; a tap before the player is ready starts PiP once it is.
    static func showsButton(supported: Bool) -> Bool { supported }
}
