import SwiftUI

/// The last screen of a pairing: "Linked ✓ <other device>".
struct PairLinkedView: View {
    let name: String
    let already: Bool
    /// This iPhone shares its vault for the linked device's copy.
    var keepOpen = false
    let done: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.appSystem(size: 56))
                .foregroundColor(.havenOnline)
            Text("Linked ✓ \(name)")
                .font(.appTitle3)
                .multilineTextAlignment(.center)
            Text(already ? MeshPairing.alreadyLinkedText : "It shows a green dot under Your devices once both are on the mesh.")
                .font(.appCaption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if keepOpen {
                Text(OtherVaultCopy.keepOpenLine)
                    .font(.appCaption.weight(.semibold))
                    .foregroundColor(.havenPurple)
                    .multilineTextAlignment(.center)
            }
            Button("Done", action: done)
                .buttonStyle(.borderedProminent)
                .tint(.havenPurple)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
