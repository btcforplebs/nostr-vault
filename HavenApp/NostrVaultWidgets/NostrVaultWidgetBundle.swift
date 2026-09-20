import SwiftUI
import WidgetKit

@main
struct NostrVaultWidgetBundle: WidgetBundle {
    var body: some Widget {
        FeedGlanceWidget()
        QuickActionsWidget()
        MosaicWidget()
        LockScreenWidget()
    }
}
