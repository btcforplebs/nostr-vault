import SwiftUI

/// The "Delete Account" row (Settings › Accounts and Advanced): opens
/// LeaveNostrForeverView.
struct DeleteAccountButton: View {
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label("Delete Account", systemImage: "person.crop.circle.badge.xmark")
                .foregroundColor(.red)
        }
    }
}
