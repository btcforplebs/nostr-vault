import SwiftUI

/// My Web's three switches for the globe's live stars
/// (RESEARCH/NV_GLOBE_STARS_FINAL.md rule 7, Logen 2026-11-19): Live stars
/// itself, Friends of friends (hop 2) and Likes, reposts and zaps. The two
/// under it only matter while Live stars is on, so they dim when it is off.
struct LiveStarsSwitches: View {
    @AppStorage(LiveArcsSetting.key) private var on = LiveArcsSetting.defaultOn
    @AppStorage(LiveArcsSetting.friendsKey) private var friends = true
    @AppStorage(LiveArcsSetting.extrasKey) private var extras = true

    var body: some View {
        VStack(spacing: 0) {
            row($on, icon: "antenna.radiowaves.left.and.right", title: "Live stars")
            DashboardDivider()
            row($friends, icon: "person.3", title: "Friends of friends (hop 2)")
                .disabled(!on)
            DashboardDivider()
            row($extras, icon: "bolt.heart", title: "Likes, reposts and zaps")
                .disabled(!on)
        }
    }

    private func row(_ isOn: Binding<Bool>, icon: String, title: String) -> some View {
        Toggle(isOn: isOn) { RowLabel(icon: icon, title: title) }
            .tint(.havenPurple)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }
}

/// The same three switches as a menu: the Mac's WoT bar antenna, which has
/// no My Web page.
struct LiveStarsMenu: View {
    @AppStorage(LiveArcsSetting.key) private var on = LiveArcsSetting.defaultOn
    @AppStorage(LiveArcsSetting.friendsKey) private var friends = true
    @AppStorage(LiveArcsSetting.extrasKey) private var extras = true

    var body: some View {
        Menu {
            Toggle("Live stars", isOn: $on)
            Toggle("Friends of friends (hop 2)", isOn: $friends).disabled(!on)
            Toggle("Likes, reposts and zaps", isOn: $extras).disabled(!on)
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(on ? Color.havenPurple : .secondary)
        }
        .menuIndicator(.hidden)
        .help("Live stars")
        .accessibilityLabel(Text("Live stars"))
        .accessibilityValue(Text(on ? "On" : "Off"))
    }
}
