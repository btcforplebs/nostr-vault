import SwiftUI

/// The My Web dashboard's "What flies" switches, under the feed switches:
/// which sorts of arrival fly across the globe, and whether the globe spins
/// on its own. Each is kept across launches; the bar's antenna stays the
/// main switch.
struct LiveArcsShowSection: View {
    /// The antenna: with it off, the sorts can't fly anyway.
    let liveArcsOn: Bool

    @AppStorage(LiveArcsSetting.key(.note)) private var notesOn = true
    @AppStorage(LiveArcsSetting.key(.reply)) private var repliesOn = true
    @AppStorage(LiveArcsSetting.key(.repost)) private var repostsOn = true
    @AppStorage(LiveArcsSetting.key(.reaction)) private var reactionsOn = true
    @AppStorage(LiveArcsSetting.key(.zap)) private var zapsOn = true
    @AppStorage(LiveArcsSetting.spinKey) private var spinOn = true

    var body: some View {
        DashboardSection(title: "What flies") {
            row(icon: "text.bubble", title: "New notes", detail: "A star for each new note", isOn: $notesOn)
                .disabled(!liveArcsOn)
            DashboardDivider()
            row(icon: "arrowshape.turn.up.left", title: "Replies",
                detail: "A star from who replied to who they answered", isOn: $repliesOn)
                .disabled(!liveArcsOn)
            DashboardDivider()
            row(icon: "arrow.2.squarepath", title: "Reposts",
                detail: "A star from who reposted to who wrote it", isOn: $repostsOn)
                .disabled(!liveArcsOn)
            DashboardDivider()
            row(icon: "heart", title: "Reactions",
                detail: "A smaller star from who reacted to who they reacted to", isOn: $reactionsOn)
                .disabled(!liveArcsOn)
            DashboardDivider()
            row(icon: "bolt.fill", title: "Zaps",
                detail: "A lightning bolt from the zapper. Bigger zaps strike harder", isOn: $zapsOn)
                .disabled(!liveArcsOn)
            DashboardDivider()
            row(icon: "globe.americas", title: "Globe spinning",
                detail: "The globe turns slowly on its own", isOn: $spinOn)
        }
    }

    private func row(icon: String, title: String, detail: String, isOn: Binding<Bool>) -> some View {
        DashboardRow(icon: icon, title: title, detail: detail, state: .info) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(.havenPurple)
        }
    }
}
