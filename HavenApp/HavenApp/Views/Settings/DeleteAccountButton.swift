import SwiftUI

/// The "Delete Account" row at the bottom of an account's page (Settings ›
/// Accounts › the account): opens DeleteAccountView.
struct DeleteAccountButton: View {
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label("Delete Account", systemImage: "person.crop.circle.badge.xmark")
                .foregroundColor(.red)
        }
    }
}
