import SwiftUI

/// Someone's profile, from anywhere that opens one: a note, a list, search,
/// a link, a notification. Always `PersonProfileView`; the Profile tab is
/// `MyProfileView` and is never built through here.
struct ProfileView: View {
    let pubkey: String
    var embeddedInNavigation: Bool = false
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        // Skipped when only the host redrew; see `PersonProfileView`.
        PersonProfileView(pubkey: pubkey, embeddedInNavigation: embeddedInNavigation, onDismiss: onDismiss)
            .equatable()
            // As a sheet, a stack behind it must not take its links: they
            // would push out of sight. Its notes open as sheets (Logen).
            .transformEnvironment(\.pushNoteID) { if !embeddedInNavigation { $0 = nil } }
    }
}
