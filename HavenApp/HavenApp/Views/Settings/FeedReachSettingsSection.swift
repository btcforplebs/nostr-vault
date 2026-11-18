import SwiftUI

/// Settings › Feeds › Reach: how far each feed reaches (`FeedReach`). "Your
/// web" keeps a feed to the people in your web of trust; "+ a few one hop
/// out" lets in a rationed few followed by some of your follows, too few to
/// be in your web. Underrated starts there; every other feed starts on your
/// web.
struct FeedReachSettingsSection: View {
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        Section {
            ForEach(FeedReach.modes, id: \.self) { mode in
                Picker(selection: binding(for: mode)) {
                    ForEach([WebGate.Reach.web, .webAndHop3], id: \.self) { reach in
                        Text(FeedReach.label(reach)).tag(reach)
                    }
                } label: {
                    Text(mode.displayName)
                }
            }
        } header: {
            Text("Reach")
        } footer: {
            Text("How far each feed reaches past the people you follow. One hop out shows at most one post per person and a few per feed. Global's Everyone shield still opens Global to everyone.")
        }
    }

    private func binding(for mode: FeedMode) -> Binding<WebGate.Reach> {
        Binding {
            FeedReach.reach(for: mode, settings: configService.config.feedReach)
        } set: { reach in
            configService.config.feedReach = FeedReach.setting(reach, for: mode, in: configService.config.feedReach)
            FeedService.shared.recomputeFilteredNotes()
        }
    }
}
