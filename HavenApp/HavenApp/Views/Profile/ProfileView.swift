import SwiftUI

/// Someone's profile, from anywhere that opens one: a note, a list, search,
/// a link, a notification. Always `PersonProfileView`; the Profile tab is
/// `MyProfileView` and is never built through here.
struct ProfileView: View {
    let pubkey: String
    var embeddedInNavigation: Bool = false
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        PersonProfileView(pubkey: pubkey, embeddedInNavigation: embeddedInNavigation, onDismiss: onDismiss)
    }
}
