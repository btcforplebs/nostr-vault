import SwiftUI

/// The line under a profile's name when that account's secret key sits in a
/// profile we loaded (`PublicKeyRegistry`): anyone can post as it. Nothing
/// shows otherwise, and nothing is fetched to find out.
struct PublicKeyWarning: View {
    let pubkey: String
    @State private var isPublic = false

    var body: some View {
        Group {
            if isPublic {
                Label(SecretKeyLeak.publicKeyLabel, systemImage: "exclamationmark.triangle.fill")
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .accessibilityElement(children: .combine)
            } else {
                // Something to hang onAppear on; takes no room.
                Color.clear.frame(height: 0)
            }
        }
        .onAppear { refresh() }
        .onChange(of: pubkey) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: PublicKeyRegistry.changed)) { _ in refresh() }
    }

    private func refresh() {
        isPublic = PublicKeyRegistry.shared.isPublic(pubkey)
    }
}
